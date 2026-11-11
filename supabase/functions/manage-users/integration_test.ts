// End-to-end test of manage-users against the LOCAL Supabase stack only.
// Skipped unless MANAGE_USERS_IT=1. Run (stack started, function served):
//   MANAGE_USERS_IT=1 FN_URL=http://127.0.0.1:54321/functions/v1/manage-users \
//   SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=... SUPABASE_SERVICE_ROLE_KEY=... \
//   SIGN_IN_PEPPER=<the same value the served function has> \
//   deno test --allow-net --allow-env integration_test.ts
// It creates its own local owner, manager and outsider accounts (unique per run).
import { assert, assertEquals } from '@std/assert';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { LOGIN_EMAIL_DOMAIN, toLoginEmail } from '../_shared/loginId.ts';
import { pepperPassword } from '../_shared/pepper.ts';

const enabled = Deno.env.get('MANAGE_USERS_IT') === '1';
const url = Deno.env.get('SUPABASE_URL') ?? '';
if (enabled && !/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(url)) {
  throw new Error('integration_test.ts runs against a local stack only');
}

const opts = { auth: { persistSession: false, autoRefreshToken: false } };
const run = Date.now().toString(36);

function anon(): SupabaseClient {
  return createClient(url, Deno.env.get('SUPABASE_ANON_KEY') ?? '', opts);
}

async function call(token: string | null, body: unknown, origin?: string) {
  const res = await fetch(Deno.env.get('FN_URL') ?? '', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(origin ? { Origin: origin } : {}),
    },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.json(), headers: res.headers };
}

// Same mapping as the sign-in screen (src/lib/loginId.ts ≡ _shared/loginId.ts). GoTrue directly, like
// the sign-in function does: first the PEPPERED password (accounts made or reset by manage-users), then
// the typed one (fixture accounts created here with a plain password, like pre-pepper accounts).
async function signIn(typedUsername: string, password: string) {
  const client = anon();
  const email = toLoginEmail(typedUsername);
  if (!email) throw new Error('invalid username');
  const peppered = await pepperPassword(Deno.env.get('SIGN_IN_PEPPER') ?? '', email, password);
  const first = await client.auth.signInWithPassword({ email, password: peppered });
  if (!first.error) return { client, session: first.data.session, error: null };
  const { data, error } = await client.auth.signInWithPassword({ email, password });
  return { client, session: data.session, error };
}

Deno.test({
  name: 'manage-users end to end (local stack)',
  ignore: !enabled,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async (t) => {
    const service = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', opts);
    const { data: plantRow } = await service.from('plants').select('id, org_id').limit(1).single();
    assert(plantRow, 'seeded plant');
    const plant: { id: string; org_id: string } = plantRow;

    // Local fixtures: an owner, a manager, and a user only in a second (fixture) plant.
    // A value with @ is a full (real) email, like the owner's own dashboard-created account.
    async function fixtureUser(username: string, role: string, plantId: string | null) {
      const { data, error } = await service.auth.admin.createUser({
        email: username.includes('@') ? username : `${username}@${LOGIN_EMAIL_DOMAIN}`,
        password: 'fixture-password-1',
        email_confirm: true,
      });
      if (error) throw error;
      const { error: mErr } = await service.from('memberships').insert({
        user_id: data.user.id,
        org_id: plant.org_id,
        plant_id: plantId,
        role,
      });
      if (mErr) throw mErr;
      return data.user.id;
    }
    await fixtureUser(`it-owner-${run}`, 'owner', plant.id);
    await fixtureUser(`it-mgr-${run}`, 'manager', plant.id);
    const orgOwnerId = await fixtureUser(`it-orgowner-${run}`, 'owner', null);
    const realEmail = `it-real-owner-${run}@example.com`;
    await fixtureUser(realEmail, 'owner', plant.id);

    const ownerSignIn = (await signIn(`it-owner-${run}`, 'fixture-password-1')).session;
    const managerSignIn = (await signIn(`it-mgr-${run}`, 'fixture-password-1')).session;
    assert(ownerSignIn && managerSignIn, 'fixture sign-in');
    const owner = ownerSignIn;
    const manager = managerSignIn;
    const newName = `it-new-${run}`;
    let newUserId = '';
    let tempPassword = '';
    let resetPassword = '';

    await t.step(
      'dashboard-created owner (<username>@accounts…) signs in by username',
      async () => {
        // Created like the owner's own account: Auth dashboard / admin API, confirmed, no flag.
        const { session, error } = await signIn(
          `  IT-Owner-${run.toUpperCase()} `,
          'fixture-password-1',
        );
        assertEquals(error, null);
        assertEquals(session?.user.email, `it-owner-${run}@${LOGIN_EMAIL_DOMAIN}`);
        assertEquals(
          session?.user.app_metadata.must_change_password,
          undefined,
          'not forced to change',
        );
        const wrong = await signIn(`it-owner-${run}`, 'not-the-password');
        const unknown = await signIn(`it-nobody-${run}`, 'not-the-password');
        assertEquals(
          wrong.error?.code,
          unknown.error?.code,
          'same error for wrong password and unknown user',
        );
        assertEquals(wrong.error?.status, unknown.error?.status);
      },
    );

    await t.step(
      "owner's real-email account: full email typed as the username signs in",
      async () => {
        const { session, error } = await signIn(
          ` IT-Real-Owner-${run.toUpperCase()}@Example.com `,
          'fixture-password-1',
        );
        assertEquals(error, null);
        assertEquals(session?.user.email, realEmail);
        assert(session);
        // That owner can manage people like any other owner.
        const r = await call(session.access_token, {
          action: 'create',
          plant_id: plant.id,
          username: `it-bymail-${run}`,
          display_name: 'Created By Real Owner',
          role: 'manager',
          can_manage_staff: true,
        });
        assertEquals(r.status, 201);
        const list = await call(session.access_token, { action: 'list', plant_id: plant.id });
        const self = list.body.people.find((x: { is_self: boolean }) => x.is_self);
        assertEquals(self.username, null, 'real email is never returned as a username');
        assert(!JSON.stringify(list.body).includes('@'), 'no email anywhere in the list');
      },
    );

    await t.step('list never returns an email address', async () => {
      const r = await call(owner.access_token, { action: 'list', plant_id: plant.id });
      assertEquals(r.status, 200);
      assert(!JSON.stringify(r.body).includes('@'), 'no @ anywhere in the list response');
    });

    await t.step('no token → 401 NOT_AUTHORIZED', async () => {
      const r = await call(null, { action: 'list', plant_id: plant.id });
      assertEquals(r.status, 401);
      assertEquals(r.body.code, 'NOT_AUTHORIZED');
    });

    await t.step('owner creates a lead → 201 with a one-time temp password', async () => {
      const r = await call(owner.access_token, {
        action: 'create',
        plant_id: plant.id,
        username: newName,
        display_name: 'Ana Prueba',
        role: 'lead',
      });
      assertEquals(r.status, 201, JSON.stringify(r.body.code));
      assertEquals(r.body.username, newName);
      assert(r.body.temp_password.length >= 14);
      assertEquals(r.headers.get('cache-control'), 'no-store');
      newUserId = r.body.user_id;
      tempPassword = r.body.temp_password;
      const { data: m } = await service
        .from('memberships')
        .select('org_id, plant_id, role, can_manage_staff')
        .eq('user_id', newUserId)
        .single();
      assertEquals(m, {
        org_id: plant.org_id,
        plant_id: plant.id,
        role: 'lead',
        can_manage_staff: false,
      });
      const { data: audit } = await service
        .from('audit_log')
        .select('actor_user_id')
        .eq('entity', 'memberships')
        .eq('action', 'memberships.insert')
        .eq('after->>user_id', newUserId)
        .single();
      assertEquals(
        audit?.actor_user_id,
        owner.user.id,
        'membership insert audited with the owner as actor',
      );
    });

    await t.step('duplicate username → 409 USERNAME_TAKEN', async () => {
      const r = await call(owner.access_token, {
        action: 'create',
        plant_id: plant.id,
        username: newName,
        display_name: 'Otra',
        role: 'viewer',
      });
      assertEquals(r.status, 409);
      assertEquals(r.body.code, 'USERNAME_TAKEN');
    });

    await t.step('can_manage_staff on a non-manager → 400 VALIDATION_FAILED', async () => {
      const r = await call(owner.access_token, {
        action: 'create',
        plant_id: plant.id,
        username: `it-bad-${run}`,
        display_name: 'X',
        role: 'lead',
        can_manage_staff: true,
      });
      assertEquals(r.status, 400);
      assertEquals(r.body.code, 'VALIDATION_FAILED');
    });

    await t.step('manager calling create → 403 NOT_AUTHORIZED, no user created', async () => {
      const r = await call(manager.access_token, {
        action: 'create',
        plant_id: plant.id,
        username: `it-mgrmade-${run}`,
        display_name: 'Nope',
        role: 'viewer',
      });
      assertEquals(r.status, 403);
      assertEquals(r.body.code, 'NOT_AUTHORIZED');
      const { data } = await service.auth.admin.listUsers({ perPage: 1000 });
      assert(!data.users.some((u) => u.email?.startsWith(`it-mgrmade-${run}@`)));
    });

    await t.step('manager calling list / reset / deactivate → 403', async () => {
      for (const action of ['reset_password', 'deactivate']) {
        const r = await call(manager.access_token, {
          action,
          plant_id: plant.id,
          user_id: newUserId,
        });
        assertEquals(r.status, 403);
      }
      assertEquals(
        (await call(manager.access_token, { action: 'list', plant_id: plant.id })).status,
        403,
      );
    });

    // Owner 2026-11-10: the password the owner gives is the one the person keeps (no forced change).
    await t.step('sign in with the first password → no forced change', async () => {
      const { client, session, error } = await signIn(newName, tempPassword);
      assertEquals(error, null);
      assertEquals(session?.user.app_metadata.must_change_password, false);
      const { data: plants } = await client.from('plants').select('id');
      assertEquals(plants?.length, 1, 'the new account reads its plant right away');
      const { data: profile } = await client.from('profiles').select('full_name');
      assertEquals(profile?.[0]?.full_name, 'Ana Prueba', 'own profile still readable');
    });

    await t.step(
      'change_own_password: rejects wrong, short and same; then changes it',
      async () => {
        const { client, session: maybeSession } = await signIn(newName, tempPassword);
        assert(maybeSession);
        const session = maybeSession;
        const wrong = await call(session.access_token, {
          action: 'change_own_password',
          current_password: 'not-the-temp-password',
          new_password: 'my new password 1',
        });
        assertEquals([wrong.status, wrong.body.reason], [400, 'wrong_current_password']);
        const short = await call(session.access_token, {
          action: 'change_own_password',
          current_password: tempPassword,
          new_password: 'short',
        });
        assertEquals([short.status, short.body.reason], [400, 'password_too_short']);
        const same = await call(session.access_token, {
          action: 'change_own_password',
          current_password: tempPassword,
          new_password: tempPassword,
        });
        assertEquals([same.status, same.body.reason], [400, 'same_password']);
        const ok = await call(session.access_token, {
          action: 'change_own_password',
          current_password: tempPassword,
          new_password: 'my new password 1',
        });
        assertEquals(ok.status, 200, JSON.stringify(ok.body));
        const { data: refreshed } = await client.auth.refreshSession();
        assertEquals(refreshed.session?.user.app_metadata.must_change_password, false);
        const { data: plants } = await client.from('plants').select('id');
        assertEquals(plants?.length, 1, 'after the change the lead reads its plant again');
        assertEquals(
          refreshed.session?.user.app_metadata.provider,
          'email',
          'app_metadata merged, not replaced',
        );
        const again = await signIn(newName, 'my new password 1');
        assertEquals(again.error, null);
        assertEquals(again.session?.user.app_metadata.must_change_password, false);
        assert((await signIn(newName, tempPassword)).error, 'temp password no longer works');
      },
    );

    await t.step('M1: a manager cannot change their own login email', async () => {
      const { data: before } = await service.auth.admin.getUserById(manager.user.id);
      const res = await fetch(`${url}/auth/v1/user`, {
        method: 'PUT',
        headers: {
          apikey: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
          Authorization: `Bearer ${manager.access_token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ email: `x-${run}@${LOGIN_EMAIL_DOMAIN}` }),
      });
      await res.body?.cancel();
      const { data: after } = await service.auth.admin.getUserById(manager.user.id);
      assertEquals(after.user?.email, before.user?.email, 'email unchanged (needs confirmation)');
      assertEquals(after.user?.email, `it-mgr-${run}@${LOGIN_EMAIL_DOMAIN}`);
      // Still signs in with the original username.
      assertEquals((await signIn(`it-mgr-${run}`, 'fixture-password-1')).error, null);
    });

    await t.step('a lead cannot set its own flag through the Auth API', async () => {
      const { client } = await signIn(newName, 'my new password 1');
      await client.auth.updateUser({ data: { must_change_password: false } });
      const { data } = await service.auth.admin.getUserById(newUserId);
      assertEquals(data.user?.app_metadata.must_change_password, false);
      assertEquals(
        data.user?.user_metadata.must_change_password,
        false,
        'lands in user_metadata only',
      );
    });

    await t.step('list shows the new person with name and username', async () => {
      const r = await call(owner.access_token, { action: 'list', plant_id: plant.id });
      assertEquals(r.status, 200);
      const p = r.body.people.find((x: { user_id: string }) => x.user_id === newUserId);
      assertEquals(p.display_name, 'Ana Prueba');
      assertEquals(p.username, newName);
      assertEquals(p.manageable, true);
      // RLS hides org-wide membership rows from a plant-scoped owner, so they are not listed
      // (and canManageTarget would refuse them anyway; see the no-oracle step).
      assert(!r.body.people.some((x: { user_id: string }) => x.user_id === orgOwnerId));
    });

    await t.step('no oracle: unknown user and out-of-scope user get the same 403', async () => {
      const unknown = await call(owner.access_token, {
        action: 'reset_password',
        plant_id: plant.id,
        user_id: crypto.randomUUID(),
      });
      const orgWide = await call(owner.access_token, {
        action: 'reset_password',
        plant_id: plant.id,
        user_id: orgOwnerId,
      });
      const self = await call(owner.access_token, {
        action: 'deactivate',
        plant_id: plant.id,
        user_id: owner.user.id,
      });
      assertEquals(unknown.status, 403);
      assertEquals(orgWide.status, unknown.status);
      assertEquals(orgWide.body, unknown.body);
      assertEquals(self.body, unknown.body);
      const unknownPlant = await call(owner.access_token, {
        action: 'list',
        plant_id: crypto.randomUUID(),
      });
      assertEquals(unknownPlant.body, unknown.body);
    });

    await t.step('reset_password → the new password works, no forced change', async () => {
      const r = await call(owner.access_token, {
        action: 'reset_password',
        plant_id: plant.id,
        user_id: newUserId,
      });
      assertEquals(r.status, 200);
      resetPassword = r.body.temp_password;
      const { session, error } = await signIn(newName, resetPassword);
      assertEquals(error, null);
      assertEquals(session?.user.app_metadata.must_change_password, false);
      assert((await signIn(newName, 'my new password 1')).error, 'old password no longer works');
    });

    await t.step(
      'deactivate → memberships revoked, user banned, sign-in fails, row kept',
      async () => {
        const r = await call(owner.access_token, {
          action: 'deactivate',
          plant_id: plant.id,
          user_id: newUserId,
        });
        assertEquals(r.status, 200);
        assertEquals(r.body.banned, true);
        const { data: m } = await service
          .from('memberships')
          .select('revoked_at')
          .eq('user_id', newUserId);
        assertEquals(m?.length, 1);
        assert(m?.[0]?.revoked_at);
        const { data: u } = await service.auth.admin.getUserById(newUserId);
        assert(u.user, 'auth user kept (never deleted)');
        assert(u.user?.banned_until && new Date(u.user.banned_until) > new Date(Date.now() + 1e12));
        const { data: list } = await service.auth.admin.listUsers({ perPage: 1000 });
        assert(list.users.some((x) => x.id === newUserId));
        const attempt = await signIn(newName, resetPassword);
        assert(attempt.error, 'banned: even the correct password is refused');
        const again = await call(owner.access_token, {
          action: 'reset_password',
          plant_id: plant.id,
          user_id: newUserId,
        });
        assertEquals(again.status, 403, 'a deactivated user is out of scope');
      },
    );

    await t.step(
      'L1: create, reset and deactivate are audited with the owner as actor',
      async () => {
        const { data: rows } = await service
          .from('audit_log')
          .select('action, actor_user_id, plant_id, entity, entity_id, after')
          .eq('entity', 'users')
          .eq('entity_id', newUserId)
          .order('id');
        assertEquals(
          rows?.map((r) => r.action),
          ['users.create', 'users.reset_password', 'users.deactivate'],
        );
        for (const r of rows ?? []) {
          assertEquals(r.actor_user_id, owner.user.id);
          assertEquals(r.plant_id, plant.id);
        }
        assertEquals(rows?.[0]?.after, {
          username: newName,
          role: 'lead',
          can_manage_staff: false,
        });
        assertEquals(rows?.[2]?.after, { memberships_revoked: 1, banned: true });
        const text = JSON.stringify(rows);
        assert(
          !text.includes(tempPassword) && !text.includes(resetPassword),
          'no password in audit',
        );
        assert(!/password"\s*:\s*"/.test(text), 'no password field');
      },
    );

    await t.step('CORS: allowed origin echoed, others not', async () => {
      const ok = await call(
        owner.access_token,
        { action: 'list', plant_id: plant.id },
        'http://localhost:5173',
      );
      assertEquals(ok.headers.get('access-control-allow-origin'), 'http://localhost:5173');
      const bad = await call(
        owner.access_token,
        { action: 'list', plant_id: plant.id },
        'https://evil.example',
      );
      assertEquals(bad.headers.get('access-control-allow-origin'), null);
    });
  },
});
