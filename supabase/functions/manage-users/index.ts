// manage-users: owner-created username + password accounts (PRD A4, owner decision 2026-11-03).
// No email is ever sent. One POST endpoint; `action` selects the operation:
//   list | create | reset_password | deactivate | unlock   (owner of the plant)
//   change_own_password                                     (any signed-in user)
//
// Passwords (owner-approved 2026-11-06, _shared/passwordRules.ts): 6 digits that are not a simple
// pattern, or ≥ 10 characters, for every account (owners too: owner 2026-11-07), checked on the TYPED
// value. GoTrue stores only the PEPPERED form (_shared/pepper.ts, SIGN_IN_PEPPER, owner-approved
// 2026-11-07): create and reset_password store pepper(login, temp) and still show the owner the typed
// temporary password; change_own_password verifies the CURRENT password through the sign-in lockout
// (_shared/passwordCheck.ts) and stores pepper(login, new). Every peppered write sets
// app_metadata.pw_v = 2. No pepper configured → these three fail closed (500) before changing anything.
// The sign-in Edge Function locks a login after 5 wrong passwords in 15 minutes (escalating); `unlock`
// clears that lock and `list` reports `locked_until` per person.
//
// Authorization order (.claude/rules/edge-functions.md): verify the JWT, read the caller's
// memberships with a USER-scoped client (RLS), and only then use the service-role client for the
// steps that need it (Auth admin API, profiles). Membership writes go through the user-scoped client
// so RLS re-checks them and the memberships_audit trigger records the acting owner.
//
// Never logs passwords, tokens or request bodies.
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { corsHeaders, parseAllowedOrigins } from '../_shared/cors.ts';
import { LOGIN_EMAIL_DOMAIN, usernameFromEmail } from '../_shared/loginId.ts';
import { checkPassword, type GrantResult } from '../_shared/passwordCheck.ts';
import {
  PASSWORD_VERSION,
  pepperPassword,
  PepperMissingError,
  requirePepper,
} from '../_shared/pepper.ts';
import { canManageTarget, inPlantScope, ownsPlant, type Membership, type Plant } from './authz.ts';
import { generateTempPassword, parseRequest } from './validation.ts';

type ErrorCode =
  | 'NOT_AUTHORIZED'
  | 'VALIDATION_FAILED'
  | 'USERNAME_TAKEN'
  | 'LOCKED'
  | 'RATE_LIMITED'
  | 'INTERNAL';

const MAX_BODY_BYTES = 4096;
// Supabase Auth has no "ban forever"; 100 years.
const BAN_DURATION = '876000h';
const MEMBERSHIP_COLUMNS = 'user_id, org_id, plant_id, role, can_manage_staff, revoked_at';
const GOTRUE_TIMEOUT_MS = 10_000;

class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: ErrorCode,
    message: string,
    readonly extra: Record<string, unknown> = {},
  ) {
    super(message);
  }
}

// One message for "not an owner", "no such user", "user outside your plant" (no oracle).
const notAuthorized = () =>
  new HttpError(403, 'NOT_AUTHORIZED', 'You are not allowed to do this for that plant or person.');

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing env ${name}`);
  return value;
}

function json(status: number, body: unknown, cors: Record<string, string>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

interface MembershipRow extends Membership {
  user_id: string;
  can_manage_staff: boolean;
}

/** The pepper, or a 500 before anything changes (fail closed; the name only goes to the log). */
function pepperOrFail(): string {
  try {
    return requirePepper(Deno.env.get('SIGN_IN_PEPPER'));
  } catch (e) {
    if (e instanceof PepperMissingError)
      console.error('manage-users: SIGN_IN_PEPPER is not configured');
    throw new HttpError(500, 'INTERNAL', 'Passwords cannot be set right now.');
  }
}

/** GoTrue's password grant (server-side, publishable key). Throws on a network error. */
async function passwordGrant(email: string, password: string): Promise<GrantResult> {
  const res = await fetch(`${env('SUPABASE_URL')}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: env('SUPABASE_ANON_KEY'), 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
    signal: AbortSignal.timeout(GOTRUE_TIMEOUT_MS),
  });
  return { status: res.status, body: await res.json().catch(() => null) };
}

/** Ends the extra session a verification grant created (best effort; it would expire anyway). */
async function endSession(body: unknown): Promise<void> {
  const token = (body as { access_token?: unknown } | null)?.access_token;
  if (typeof token !== 'string') return;
  await fetch(`${env('SUPABASE_URL')}/auth/v1/logout?scope=local`, {
    method: 'POST',
    headers: { apikey: env('SUPABASE_ANON_KEY'), Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(GOTRUE_TIMEOUT_MS),
  }).catch(() => undefined);
}

/** The service-role RPC caller for the lockout functions; a store error throws. */
function lockoutRpc(service: SupabaseClient) {
  return async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await service.rpc(fn, args);
    if (error) {
      console.error('manage-users: lockout store error', fn, error.code);
      throw new Error('lockout store');
    }
    const row = Array.isArray(data) ? data[0] : data;
    return row as Record<string, unknown> | null;
  };
}

function serviceClient(): SupabaseClient {
  return createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** The plant, read through RLS: a caller with no role on it cannot see it. */
async function loadPlant(user: SupabaseClient, plantId: string): Promise<Plant> {
  const { data, error } = await user
    .from('plants')
    .select('id, org_id')
    .eq('id', plantId)
    .maybeSingle();
  if (error) throw new HttpError(500, 'INTERNAL', 'Could not read the plant.');
  if (!data) throw notAuthorized();
  return data as Plant;
}

/** All memberships of `userIds` (revoked included), read with the service client after the owner check. */
async function membershipsOf(service: SupabaseClient, userIds: string[]): Promise<MembershipRow[]> {
  if (userIds.length === 0) return [];
  const { data, error } = await service
    .from('memberships')
    .select(MEMBERSHIP_COLUMNS)
    .in('user_id', userIds);
  if (error) throw new HttpError(500, 'INTERNAL', 'Could not read memberships.');
  return (data ?? []) as MembershipRow[];
}

/** Every membership of the user, revoked ones included (security review M3). */
async function allMemberships(service: SupabaseClient, userId: string): Promise<MembershipRow[]> {
  const { data, error } = await service
    .from('memberships')
    .select(MEMBERSHIP_COLUMNS)
    .eq('user_id', userId);
  if (error) throw new HttpError(500, 'INTERNAL', 'Could not read memberships.');
  return (data ?? []) as MembershipRow[];
}

/**
 * audit_log row for an account action (security review L1). Clients have no INSERT policy on
 * audit_log, so the service client writes it with the acting owner set explicitly.
 * `details` must never contain a password.
 */
async function audit(
  service: SupabaseClient,
  actorId: string,
  plant: Plant,
  action: 'users.create' | 'users.reset_password' | 'users.deactivate' | 'users.unlock',
  targetId: string,
  details: Record<string, unknown>,
): Promise<void> {
  const { error } = await service.from('audit_log').insert({
    org_id: plant.org_id,
    plant_id: plant.id,
    actor_user_id: actorId,
    action,
    entity: 'users',
    entity_id: targetId,
    after: details,
  });
  // The account change already happened; a missing audit row is logged, not surfaced.
  if (error) console.error('manage-users: audit insert failed', action, error.code);
}

async function requireManageableTarget(
  callerId: string,
  caller: Membership[],
  targetId: string,
  plant: Plant,
): Promise<{ service: SupabaseClient; target: MembershipRow[] }> {
  if (!ownsPlant(caller, plant)) throw notAuthorized();
  const service = serviceClient();
  const target = await allMemberships(service, targetId);
  if (!canManageTarget(callerId, caller, targetId, target, plant)) throw notAuthorized();
  return { service, target: target.filter((m) => m.revoked_at === null) };
}

async function handle(req: Request): Promise<{ status: number; body: unknown }> {
  // 1. Verify the caller's JWT (also rejects banned users).
  const authHeader = req.headers.get('Authorization') ?? '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  if (!token) throw new HttpError(401, 'NOT_AUTHORIZED', 'Sign in first.');
  const user = createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: auth, error: authError } = await user.auth.getUser(token);
  if (authError || !auth.user) throw new HttpError(401, 'NOT_AUTHORIZED', 'Sign in first.');
  const callerId = auth.user.id;

  // 2. Validate the body.
  const raw = await req.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) {
    throw new HttpError(400, 'VALIDATION_FAILED', 'Request too large.');
  }
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    throw new HttpError(400, 'VALIDATION_FAILED', 'Body must be JSON.');
  }
  const parsed = parseRequest(body);
  if (!parsed.ok) {
    throw new HttpError(400, 'VALIDATION_FAILED', `Invalid: ${parsed.fields.join(', ')}`, {
      fields: parsed.fields,
      ...(parsed.reason ? { reason: parsed.reason } : {}),
    });
  }
  const input = parsed.value;

  // 3a. Any signed-in user: change their own password. The current password is verified through the
  // sign-in lockout (same login key, no IP), peppered, before anything changes.
  if (input.action === 'change_own_password') {
    const pepper = pepperOrFail();
    const email = auth.user.email?.trim().toLowerCase() ?? '';
    if (email === '') throw new HttpError(500, 'INTERNAL', 'Could not change the password.');
    if (input.current_password === input.new_password) {
      throw new HttpError(400, 'VALIDATION_FAILED', 'Choose a password you have not used.', {
        reason: 'same_password',
      });
    }
    const service = serviceClient();
    const rpc = lockoutRpc(service);
    const check = await checkPassword(
      {
        begin: async (login, ip) =>
          (await rpc('sign_in_begin', { p_login: login, p_ip: ip })) as unknown as {
            allowed: boolean;
            retry_after_seconds: number;
          },
        failed: async (login, ip) =>
          (await rpc('sign_in_failed', { p_login: login, p_ip: ip })) as unknown as {
            locked: boolean;
            retry_after_seconds: number;
          },
        succeeded: async (login, ip) => {
          await rpc('sign_in_succeeded', { p_login: login, p_ip: ip });
        },
        passwordGrant,
        pepper: (login, typed) => pepperPassword(pepper, login, typed),
        legacyPassword: async (login) =>
          (await rpc('sign_in_account_state', { p_login: login }))?.legacy_password === true,
        legacyUpgrade: Deno.env.get('SIGN_IN_LEGACY_UPGRADE') !== 'off',
      },
      email,
      email,
      input.current_password,
      null,
    );
    switch (check.kind) {
      case 'wrong':
        throw new HttpError(400, 'VALIDATION_FAILED', 'The current password is wrong.', {
          reason: 'wrong_current_password',
        });
      case 'locked':
        throw new HttpError(429, 'LOCKED', 'Too many wrong passwords. Try again later.', {
          retry_after_seconds: Math.max(1, Math.ceil(check.retryAfterSeconds)),
        });
      case 'rate_limited':
        throw new HttpError(
          429,
          'RATE_LIMITED',
          'Too many attempts right now. Try again in a minute.',
          {
            retry_after_seconds: 60,
          },
        );
      case 'error':
        throw new HttpError(500, 'INTERNAL', 'Could not change the password.');
    }
    await endSession(check.grant.body);
    // Only this function clears the flag; app_metadata is not user-writable (merged, not replaced).
    const { error } = await service.auth.admin.updateUserById(callerId, {
      password: await pepperPassword(pepper, email, input.new_password),
      app_metadata: { must_change_password: false, pw_v: PASSWORD_VERSION },
    });
    if (error) {
      console.error('manage-users: change_own_password update failed', error.code ?? error.status);
      throw new HttpError(500, 'INTERNAL', 'Could not change the password.');
    }
    return { status: 200, body: { ok: true } };
  }

  // 3b. Owner actions: caller memberships through RLS, then the plant through RLS.
  const { data: callerRows, error: callerError } = await user
    .from('memberships')
    .select(MEMBERSHIP_COLUMNS)
    .eq('user_id', callerId)
    .is('revoked_at', null);
  if (callerError) throw new HttpError(500, 'INTERNAL', 'Could not read your access.');
  const caller = (callerRows ?? []) as MembershipRow[];
  const plant = await loadPlant(user, input.plant_id);
  if (!ownsPlant(caller, plant)) throw notAuthorized();

  switch (input.action) {
    case 'list': {
      // Memberships that apply to this plant, through RLS (owner can read them).
      const { data, error } = await user
        .from('memberships')
        .select(MEMBERSHIP_COLUMNS)
        .eq('org_id', plant.org_id)
        .or(`plant_id.eq.${plant.id},plant_id.is.null`)
        .is('revoked_at', null)
        .neq('role', 'display');
      if (error) throw new HttpError(500, 'INTERNAL', 'Could not read memberships.');
      const rows = (data ?? []) as MembershipRow[];
      const ids = [...new Set(rows.map((r) => r.user_id))];
      const service = serviceClient();
      const [profiles, allRows, users] = await Promise.all([
        service.from('profiles').select('user_id, full_name').in('user_id', ids),
        membershipsOf(service, ids),
        Promise.all(ids.map((id) => service.auth.admin.getUserById(id))),
      ]);
      if (profiles.error) throw new HttpError(500, 'INTERNAL', 'Could not read names.');
      // Sign-in locks (sign-in Edge Function), keyed by the normalised login = the auth email.
      const emails = users
        .map((u) => u?.data.user?.email?.toLowerCase() ?? '')
        .filter((e) => e.length > 0);
      const locks = new Map<string, string>();
      if (emails.length > 0) {
        const { data: lockRows, error: lockError } = await service.rpc('sign_in_lock_status', {
          p_logins: emails,
        });
        if (lockError) throw new HttpError(500, 'INTERNAL', 'Could not read sign-in locks.');
        for (const r of (lockRows ?? []) as { login: string; locked_until: string }[]) {
          locks.set(r.login, r.locked_until);
        }
      }
      const names = new Map(
        (profiles.data ?? []).map((p: { user_id: string; full_name: string | null }) => [
          p.user_id,
          p.full_name,
        ]),
      );
      const people = ids.map((id, i) => {
        // Usernames only: an account outside the mapped domain gets null, never its email.
        const email = users[i]?.data.user?.email ?? '';
        return {
          user_id: id,
          username: usernameFromEmail(email),
          display_name: names.get(id) ?? null,
          memberships: rows
            .filter((r) => r.user_id === id)
            .map((r) => ({
              role: r.role,
              org_wide: r.plant_id === null,
              can_manage_staff: r.can_manage_staff,
            })),
          is_self: id === callerId,
          /** Set while the person's sign-in is locked (5 wrong passwords); People offers Unlock. */
          locked_until: locks.get(email.toLowerCase()) ?? null,
          manageable: canManageTarget(
            callerId,
            caller,
            id,
            allRows.filter((m) => m.user_id === id),
            plant,
          ),
        };
      });
      people.sort((a, b) =>
        (a.display_name ?? a.username ?? '').localeCompare(b.display_name ?? b.username ?? ''),
      );
      return { status: 200, body: { people } };
    }

    case 'create': {
      // Only an owner reaches here, so owner / can_manage_staff grants are owner-made. The new
      // membership is always plant-scoped: a plant owner can never create an org-wide one.
      const pepper = pepperOrFail();
      const service = serviceClient();
      // The owner's chosen first password (validated at parse), else a generated one. GoTrue stores
      // only its peppered form; the owner is shown the typed form.
      const tempPassword = input.password ?? generateTempPassword();
      const email = `${input.username}@${LOGIN_EMAIL_DOMAIN}`;
      const { data: created, error: createError } = await service.auth.admin.createUser({
        email,
        password: await pepperPassword(pepper, email, tempPassword),
        email_confirm: true,
        // Owner 2026-11-10: the password the owner gives is the one the person keeps (no forced change).
        app_metadata: { must_change_password: false, pw_v: PASSWORD_VERSION },
      });
      if (createError || !created.user) {
        if (createError?.code === 'email_exists') {
          throw new HttpError(409, 'USERNAME_TAKEN', 'That username is already in use.');
        }
        console.error('manage-users: createUser failed', createError?.code ?? createError?.status);
        throw new HttpError(500, 'INTERNAL', 'Could not create the account.');
      }
      const newId = created.user.id;
      try {
        const { error: profileError } = await service
          .from('profiles')
          .insert({ user_id: newId, full_name: input.display_name });
        if (profileError) throw profileError;
        const { error: memberError } = await user.from('memberships').insert({
          user_id: newId,
          org_id: plant.org_id,
          plant_id: plant.id,
          role: input.role,
          can_manage_staff: input.can_manage_staff,
        });
        if (memberError) throw memberError;
      } catch (e) {
        // Roll back: no orphan auth user. Safe to hard-delete: created seconds ago, no history.
        const code = (e as { code?: string }).code ?? '';
        console.error('manage-users: create rollback', code);
        const { error: delError } = await service.auth.admin.deleteUser(newId);
        if (delError) console.error('manage-users: rollback deleteUser failed', delError.code);
        throw new HttpError(500, 'INTERNAL', 'Could not create the account.');
      }
      await audit(service, callerId, plant, 'users.create', newId, {
        username: input.username,
        role: input.role,
        can_manage_staff: input.can_manage_staff,
      });
      return {
        status: 201,
        // A password the owner typed is never echoed back.
        body: {
          user_id: newId,
          username: input.username,
          temp_password: input.password === undefined ? tempPassword : null,
        },
      };
    }

    case 'reset_password': {
      const { service } = await requireManageableTarget(callerId, caller, input.user_id, plant);
      const pepper = pepperOrFail();
      // The owner's chosen temporary password (validated at parse), else a generated one. GoTrue stores
      // only its peppered form (keyed by the target's login email); the owner is shown the typed form.
      const tempPassword = input.password ?? generateTempPassword();
      const { data: target, error: targetError } = await service.auth.admin.getUserById(
        input.user_id,
      );
      const targetEmail = target?.user?.email?.trim().toLowerCase() ?? '';
      if (targetError || targetEmail === '') {
        console.error(
          'manage-users: reset_password lookup failed',
          targetError?.code ?? 'no email',
        );
        throw new HttpError(500, 'INTERNAL', 'Could not reset the password.');
      }
      const { error } = await service.auth.admin.updateUserById(input.user_id, {
        password: await pepperPassword(pepper, targetEmail, tempPassword),
        // Owner 2026-11-10: the password the owner gives is the one the person keeps (no forced change).
        app_metadata: { must_change_password: false, pw_v: PASSWORD_VERSION },
      });
      if (error) {
        console.error('manage-users: reset_password failed', error.code ?? error.status);
        throw new HttpError(500, 'INTERNAL', 'Could not reset the password.');
      }
      await audit(service, callerId, plant, 'users.reset_password', input.user_id, {
        must_change_password: false,
      });
      return {
        status: 200,
        body: {
          user_id: input.user_id,
          temp_password: input.password === undefined ? tempPassword : null,
        },
      };
    }

    case 'unlock': {
      // Same authorization as reset_password; the lock is keyed by the login (= the auth email).
      const { service } = await requireManageableTarget(callerId, caller, input.user_id, plant);
      const { data: target, error: userError } = await service.auth.admin.getUserById(
        input.user_id,
      );
      const email = target?.user?.email?.toLowerCase() ?? '';
      if (userError || email === '') {
        console.error('manage-users: unlock user lookup failed', userError?.code ?? 'no email');
        throw new HttpError(500, 'INTERNAL', 'Could not unlock.');
      }
      const { data: wasLocked, error } = await service.rpc('sign_in_unlock', { p_login: email });
      if (error) {
        console.error('manage-users: unlock failed', error.code);
        throw new HttpError(500, 'INTERNAL', 'Could not unlock.');
      }
      await audit(service, callerId, plant, 'users.unlock', input.user_id, {
        was_locked: wasLocked === true,
      });
      return { status: 200, body: { user_id: input.user_id, unlocked: true } };
    }

    case 'deactivate': {
      const { service, target } = await requireManageableTarget(
        callerId,
        caller,
        input.user_id,
        plant,
      );
      // Revoke (never delete: history references the user) through RLS so it is audited.
      const { data: revoked, error } = await user
        .from('memberships')
        .update({ revoked_at: new Date().toISOString() })
        .eq('user_id', input.user_id)
        .eq('org_id', plant.org_id)
        .or(`plant_id.eq.${plant.id},plant_id.is.null`)
        .is('revoked_at', null)
        .select('user_id');
      if (error || !revoked || revoked.length === 0) {
        console.error('manage-users: deactivate update failed', error?.code ?? 'no rows');
        throw new HttpError(500, 'INTERNAL', 'Could not deactivate.');
      }
      // Ban in Auth only when nothing else is left (another plant may still need the account).
      const remaining = target.filter((m) => !inPlantScope(m, plant));
      let banned = false;
      if (remaining.length === 0) {
        const { error: banError } = await service.auth.admin.updateUserById(input.user_id, {
          ban_duration: BAN_DURATION,
        });
        if (banError) {
          console.error('manage-users: ban failed', banError.code ?? banError.status);
          throw new HttpError(500, 'INTERNAL', 'Access removed, but sign-in block failed. Retry.');
        }
        banned = true;
      }
      await audit(service, callerId, plant, 'users.deactivate', input.user_id, {
        memberships_revoked: revoked.length,
        banned,
      });
      return { status: 200, body: { user_id: input.user_id, deactivated: true, banned } };
    }
  }
}

Deno.serve(async (req) => {
  const cors = corsHeaders(
    req.headers.get('Origin'),
    parseAllowedOrigins(Deno.env.get('ALLOWED_ORIGINS')),
  );
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') {
    return json(405, { code: 'VALIDATION_FAILED', message: 'Use POST.' }, cors);
  }
  try {
    const { status, body } = await handle(req);
    return json(status, body, cors);
  } catch (e) {
    if (e instanceof HttpError) {
      return json(e.status, { code: e.code, message: e.message, ...e.extra }, cors);
    }
    console.error('manage-users: unexpected error', e instanceof Error ? e.name : 'unknown');
    return json(500, { code: 'INTERNAL', message: 'Something went wrong.' }, cors);
  }
});
