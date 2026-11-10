import { assert, assertEquals, assertFalse, assertNotEquals } from '@std/assert';
import { pepperPassword } from '../_shared/pepper.ts';
import {
  clientIp,
  type FailResult,
  type GateResult,
  type GrantResult,
  headerDiagnostic,
  parseBody,
  parseDeviceBody,
  pickSession,
  signIn,
  type SignInDeps,
} from './logic.ts';

const PEPPER = 'test-pepper-0123456789abcdef0123456789';
const DENISE = 'denise@accounts.adbheadquarters.com';
const DEVICE = 'ab'.repeat(32);
const DENISE_MEMBER = '0b9d3c4e-1111-4222-8333-944455556666';

const SESSION = {
  access_token: 'at',
  refresh_token: 'rt',
  expires_in: 3600,
  expires_at: 1_800_000_000,
  token_type: 'bearer',
  user: { id: 'u1', email: DENISE, app_metadata: {} },
  weak_password: null,
};

interface Calls {
  begin: [string, string | null][];
  failed: [string, string | null][];
  succeeded: [string, string | null][];
  grant: [string, string][];
  legacy: string[];
  upgrade: [string, string, boolean][];
}

/**
 * A fake lockout store (5 failures lock, like the DB) and a fake GoTrue with one known account, Denise.
 * By default her stored password is the PEPPERED form of `password` (483920). With `legacy: true` it is
 * the typed form (an account from before the pepper, app_metadata.pw_v not 2).
 */
function fake(
  opts: {
    password?: string;
    legacy?: boolean;
    legacyUpgrade?: boolean;
    upgradeThrows?: boolean;
    grant?: (email: string, pw: string) => GrantResult | Promise<GrantResult>;
    gate?: GateResult;
    fail?: FailResult;
    storeThrows?: 'begin' | 'failed' | 'succeeded' | 'legacy' | 'device';
  } = {},
) {
  const calls: Calls = { begin: [], failed: [], succeeded: [], grant: [], legacy: [], upgrade: [] };
  const failures = new Map<string, number>();
  const typed = opts.password ?? '483920';
  // A real admin password change re-stores the peppered form and ends existing sessions (E2E B1).
  let upgraded = false;
  const deps: SignInDeps = {
    begin(login, ip) {
      calls.begin.push([login, ip]);
      if (opts.storeThrows === 'begin') return Promise.reject(new Error('db'));
      if (opts.gate) return Promise.resolve(opts.gate);
      const n = failures.get(login) ?? 0;
      return Promise.resolve(
        n >= 5
          ? { allowed: false, retry_after_seconds: 900 }
          : { allowed: true, retry_after_seconds: 0 },
      );
    },
    failed(login, ip) {
      calls.failed.push([login, ip]);
      if (opts.storeThrows === 'failed') return Promise.reject(new Error('db'));
      if (opts.fail) return Promise.resolve(opts.fail);
      const n = (failures.get(login) ?? 0) + 1;
      failures.set(login, n);
      return Promise.resolve(
        n >= 5
          ? { locked: true, retry_after_seconds: 900 }
          : { locked: false, retry_after_seconds: 0 },
      );
    },
    succeeded(login, ip) {
      calls.succeeded.push([login, ip]);
      failures.delete(login);
      return opts.storeThrows === 'succeeded' ? Promise.reject(new Error('db')) : Promise.resolve();
    },
    async passwordGrant(email, pw) {
      calls.grant.push([email, pw]);
      if (opts.grant) return await opts.grant(email, pw);
      const stored = opts.legacy && !upgraded ? typed : await pepperPassword(PEPPER, DENISE, typed);
      return email === DENISE && pw === stored
        ? { status: 200, body: upgraded ? { ...SESSION, access_token: 'after-upgrade' } : SESSION }
        : {
            status: 400,
            body: { error_code: 'invalid_credentials', msg: 'Invalid login credentials' },
          };
    },
    pepper: (login, t) => pepperPassword(PEPPER, login, t),
    legacyPassword(login) {
      calls.legacy.push(login);
      if (opts.storeThrows === 'legacy') return Promise.reject(new Error('db'));
      return Promise.resolve(login === DENISE && opts.legacy === true);
    },
    legacyUpgrade: opts.legacyUpgrade ?? true,
    // One live shared device (DEVICE) listing Denise (DENISE_MEMBER).
    devicePeople(token) {
      if (opts.storeThrows === 'device') return Promise.reject(new Error('db'));
      return Promise.resolve(
        token === DEVICE ? [{ member_id: DENISE_MEMBER, display_name: 'Denise' }] : [],
      );
    },
    deviceLogin(token, memberId) {
      if (opts.storeThrows === 'device') return Promise.reject(new Error('db'));
      return Promise.resolve(token === DEVICE && memberId === DENISE_MEMBER ? DENISE : null);
    },
    upgradePassword(userId, peppered, mustChange) {
      calls.upgrade.push([userId, peppered, mustChange]);
      if (opts.upgradeThrows) return Promise.reject(new Error('admin'));
      upgraded = true;
      return Promise.resolve();
    },
  };
  return { deps, calls };
}

const body = (username: unknown, password: unknown) => JSON.stringify({ username, password });

// ------------------------------------------------------------------------------------------------
// parseBody

Deno.test('parseBody: username (or the owner email) + password; normalised like the app', () => {
  assertEquals(parseBody(body(' Denise ', '483920')), {
    login: 'denise@accounts.adbheadquarters.com',
    email: 'denise@accounts.adbheadquarters.com',
    password: '483920',
  });
  assertEquals(
    parseBody(body('Owner.Name@Gmail.com', 'long password!'))?.email,
    'owner.name@gmail.com',
  );
  // Neither a username nor an email: still counted under its trimmed lowercased form, never sent to GoTrue.
  assertEquals(parseBody(body(' No Such User! ', 'x')), {
    login: 'no such user!',
    email: null,
    password: 'x',
  });
});

Deno.test('parseBody: rejects anything else; never more than 2 KB', () => {
  for (const raw of [
    '',
    'not json',
    'null',
    '[]',
    '"x"',
    JSON.stringify({ username: 'denise' }),
    JSON.stringify({ password: '483920' }),
    JSON.stringify({ username: 'denise', password: '483920', extra: 1 }),
    JSON.stringify({ email: 'denise', password: '483920' }),
    body(7, '483920'),
    body('denise', 483920),
    body('   ', '483920'),
    body('denise', ''),
    body('denise', 'a'.repeat(73)),
    body('a'.repeat(255), 'x'),
    body('denise', '€'.repeat(25)),
  ]) {
    assertEquals(parseBody(raw), null, raw.slice(0, 60));
  }
  assertEquals(parseBody(' '.repeat(2049)), null);
  assert(parseBody(body('denise', '483920') + ' '.repeat(2048 - 43)) !== null);
});

// ------------------------------------------------------------------------------------------------
// signIn decisions

Deno.test('right password: session for setSession, counter cleared', async () => {
  const { deps, calls } = fake();
  const out = await signIn(body('denise', '483920'), '198.51.100.7', deps);
  assertEquals(out.status, 200);
  assertEquals(Object.keys(out.body).sort(), [
    'access_token',
    'expires_at',
    'expires_in',
    'refresh_token',
    'token_type',
    'user',
  ]);
  assertEquals(calls.begin, [[DENISE, '198.51.100.7']]);
  assertEquals(calls.succeeded, [[DENISE, '198.51.100.7']]);
  assertEquals(calls.failed, []);
  // GoTrue only ever sees the peppered password, never the 6 digits.
  assertEquals(calls.grant, [[DENISE, await pepperPassword(PEPPER, DENISE, '483920')]]);
  assertEquals(calls.legacy, [], 'no legacy lookup after a peppered success');
  assertEquals(out.upgraded, undefined);
});

Deno.test(
  'wrong password: 401 WRONG; the 5th locks: 429 LOCKED; then refused before GoTrue',
  async () => {
    const { deps, calls } = fake();
    for (let i = 1; i <= 4; i++) {
      const out = await signIn(body('denise', '000001'), null, deps);
      assertEquals(out.status, 401);
      assertEquals(out.body.code, 'WRONG');
    }
    const fifth = await signIn(body('denise', '000001'), null, deps);
    assertEquals(fifth.status, 429);
    assertEquals(fifth.body.code, 'LOCKED');
    assertEquals(fifth.body.retry_after_seconds, 900);
    const sixth = await signIn(body('denise', '483920'), null, deps);
    assertEquals(sixth.status, 429);
    assertEquals(sixth.body.code, 'LOCKED');
    assertEquals(calls.grant.length, 5, 'the right password is not even tried while locked');
  },
);

Deno.test('unknown usernames get exactly the same answers (no oracle)', async () => {
  const known = fake();
  const unknown = fake();
  const a: unknown[] = [];
  const b: unknown[] = [];
  for (let i = 0; i < 6; i++) {
    a.push(await signIn(body('denise', 'nope-nope-nope'), null, known.deps));
    b.push(await signIn(body('nobody-here', 'nope-nope-nope'), null, unknown.deps));
  }
  assertEquals(a, b);
  // A value that is not a login at all: same answers, GoTrue never called.
  const junk = fake();
  const c: unknown[] = [];
  for (let i = 0; i < 6; i++)
    c.push(await signIn(body('?? !!', 'nope-nope-nope'), null, junk.deps));
  assertEquals(c, a);
  assertEquals(junk.calls.grant, []);
});

Deno.test(
  'banned, unconfirmed or any other 400 from GoTrue counts as a wrong password',
  async () => {
    const { deps, calls } = fake({
      grant: () => ({ status: 400, body: { error_code: 'user_banned', msg: 'User is banned' } }),
    });
    const out = await signIn(body('denise', '483920'), null, deps);
    assertEquals(out.status, 401);
    assertEquals(out.body.code, 'WRONG');
    assertFalse(JSON.stringify(out.body).includes('banned'));
    assertEquals(calls.failed.length, 1);
  },
);

Deno.test('GoTrue busy or broken: not counted as a failure; no details leak', async () => {
  const busy = fake({ grant: () => ({ status: 429, body: { msg: 'rate limit' } }) });
  const r1 = await signIn(body('denise', '483920'), null, busy.deps);
  assertEquals([r1.status, r1.body.code], [429, 'RATE_LIMITED']);
  assertEquals(busy.calls.failed, []);
  const broken = fake({ grant: () => ({ status: 500, body: { msg: 'db down', hint: 'x' } }) });
  const r2 = await signIn(body('denise', '483920'), null, broken.deps);
  assertEquals([r2.status, r2.body.code], [502, 'INTERNAL']);
  assertFalse(JSON.stringify(r2.body).includes('db down'));
  const offline = fake({ grant: () => Promise.reject(new Error('network')) });
  const r3 = await signIn(body('denise', '483920'), null, offline.deps);
  assertEquals([r3.status, r3.body.code], [502, 'INTERNAL']);
  const odd = fake({ grant: () => ({ status: 200, body: { access_token: 'only' } }) });
  const r4 = await signIn(body('denise', '483920'), null, odd.deps);
  assertEquals([r4.status, r4.body.code], [502, 'INTERNAL']);
});

Deno.test('lockout store down: fail closed (GoTrue never called without the check)', async () => {
  const down = fake({ storeThrows: 'begin' });
  const r = await signIn(body('denise', '483920'), null, down.deps);
  assertEquals([r.status, r.body.code], [503, 'INTERNAL']);
  assertEquals(down.calls.grant, []);
  const failDown = fake({ storeThrows: 'failed' });
  const r2 = await signIn(body('denise', 'wrong-wrong'), null, failDown.deps);
  assertEquals([r2.status, r2.body.code], [503, 'INTERNAL']);
  // A success whose counter could not be cleared still signs the person in.
  const okDown = fake({ storeThrows: 'succeeded' });
  assertEquals((await signIn(body('denise', '483920'), null, okDown.deps)).status, 200);
});

Deno.test('IP locked (gate refuses): 429 LOCKED, GoTrue not called', async () => {
  const { deps, calls } = fake({ gate: { allowed: false, retry_after_seconds: 37.2 } });
  const r = await signIn(body('denise', '483920'), '203.0.113.9', deps);
  assertEquals(r, {
    status: 429,
    body: {
      code: 'LOCKED',
      message: 'Too many wrong passwords. Try again later or ask the owner to unlock you.',
      retry_after_seconds: 38,
    },
  });
  assertEquals(calls.grant, []);
});

Deno.test(
  'bad bodies never reach the lockout store or GoTrue; responses never echo input',
  async () => {
    const { deps, calls } = fake();
    const r = await signIn('{"username":"denise","password":"483920","x":1}', null, deps);
    assertEquals([r.status, r.body.code], [400, 'VALIDATION_FAILED']);
    assertEquals(calls.begin, []);
    for (const out of [
      r,
      await signIn(body('denise', 'secret-guess-1'), null, deps),
      await signIn(body('denise', '483920'), null, deps),
    ]) {
      const text = JSON.stringify(out.body);
      assertFalse(text.includes('secret-guess-1'));
      assertFalse(text.includes('483920'));
      // No email in errors (a session's own user object is the only place it appears).
      if (out.status !== 200) assertFalse(text.includes('denise@'));
    }
  },
);

Deno.test('pickSession: only the session fields; null without both tokens', () => {
  assertEquals(pickSession({ ...SESSION, provider_token: 'p' }), {
    access_token: 'at',
    refresh_token: 'rt',
    expires_in: 3600,
    expires_at: 1_800_000_000,
    token_type: 'bearer',
    user: SESSION.user,
  });
  assertEquals(pickSession({ access_token: 'at' }), null);
  assertEquals(pickSession(null), null);
  assertEquals(pickSession('x'), null);
});

Deno.test('clientIp: only the configured trusted header; none configured → no IP', () => {
  const h = new Headers({
    'cf-connecting-ip': '203.0.113.9',
    'x-real-ip': '2001:db8::1',
    'x-forwarded-for': ' 6.6.6.6 , 198.51.100.7 , 10.0.0.1',
  });
  // Default (unset): no per-IP limit at all, whatever the caller sends (M2).
  assertEquals(clientIp(h, undefined), null);
  assertEquals(clientIp(h, ''), null);
  assertEquals(clientIp(h, 'cf-connecting-ip'), '203.0.113.9');
  assertEquals(clientIp(h, 'X-Real-IP'), '2001:db8::1');
  // X-Forwarded-For counts from the RIGHT (the leftmost entry is whatever the caller wrote).
  assertEquals(clientIp(h, 'x-forwarded-for'), '10.0.0.1');
  assertEquals(clientIp(h, 'x-forwarded-for:2'), '198.51.100.7');
  assertEquals(clientIp(h, 'x-forwarded-for:4'), null, 'fewer entries than N: no IP');
  assertEquals(clientIp(new Headers({ 'x-real-ip': '<script>' }), 'x-real-ip'), null);
  assertEquals(clientIp(h, 'x real ip'), null, 'a malformed setting is ignored');
  assertEquals(clientIp(new Headers(), 'x-real-ip'), null);
});

Deno.test(
  'headerDiagnostic: header NAMES only (and the X-Forwarded-For entry count), never values',
  () => {
    const h = new Headers({
      'cf-connecting-ip': '203.0.113.9',
      'x-forwarded-for': '6.6.6.6, 10.0.0.1',
      'x-envoy-external-address': '198.51.100.7',
      'x-sb-client-ip': '192.0.2.1',
      'content-type': 'application/json',
      origin: 'https://adb-plantboard.netlify.app',
    });
    const out = headerDiagnostic(h);
    assertEquals(out, [
      'cf-connecting-ip',
      'x-forwarded-for(entries=2)',
      'x-envoy-external-address',
      'x-sb-client-ip',
    ]);
    const text = out.join(' ');
    for (const v of ['203.0', '6.6.6.6', '10.0.0.1', '198.51', '192.0.2'])
      assertFalse(text.includes(v));
    assertEquals(headerDiagnostic(new Headers()), []);
  },
);

// ------------------------------------------------------------------------------------------------
// Pepper and the one-time upgrade of pre-pepper passwords

Deno.test('peppered: a guess of the typed 6 digits never matches what GoTrue stores', async () => {
  const { deps, calls } = fake();
  // An attacker who skips this function and sends 483920 straight to GoTrue gets a 400.
  assertEquals((await deps.passwordGrant(DENISE, '483920')).status, 400);
  calls.grant.length = 0;
  const out = await signIn(body('denise', '483920'), null, deps);
  assertEquals(out.status, 200);
  const sent = calls.grant[0]?.[1] ?? '';
  assertEquals(sent.length, 43);
  assertNotEquals(sent, '483920');
});

Deno.test('a peppered account never gets the typed-value fallback', async () => {
  const { deps, calls } = fake();
  const out = await signIn(body('denise', '000001'), null, deps);
  assertEquals([out.status, out.body.code], [401, 'WRONG']);
  assertEquals(calls.grant.length, 1, 'one grant only');
  assertEquals(calls.legacy, [DENISE], 'the legacy lookup said no');
  assertEquals(calls.failed.length, 1);
});

Deno.test(
  'pre-pepper account: the typed password signs in once and is re-stored peppered',
  async () => {
    const { deps, calls } = fake({ legacy: true, password: 'old dashboard pw 1' });
    const out = await signIn(body(' Denise ', 'old dashboard pw 1'), null, deps);
    assertEquals(out.status, 200);
    assertEquals(out.upgraded, true);
    assertEquals(
      calls.grant.map((g) => g[1] === 'old dashboard pw 1'),
      [false, true, false],
      'peppered, typed (legacy), then a fresh peppered grant after the upgrade',
    );
    // E2E B1: the upgrade ends the legacy session, so the app must get the fresh one.
    assertEquals(out.body.access_token, 'after-upgrade');
    assertEquals(calls.upgrade, [
      ['u1', await pepperPassword(PEPPER, DENISE, 'old dashboard pw 1'), false],
    ]);
    assertEquals(calls.succeeded.length, 1);
    assertEquals(calls.failed, [], 'one attempt, not two');
  },
);

Deno.test(
  "pre-pepper password that breaks today's rules: upgraded and must be changed",
  async () => {
    const { deps, calls } = fake({ legacy: true, password: 'abc123' });
    assertEquals((await signIn(body('denise', 'abc123'), null, deps)).status, 200);
    assertEquals(calls.upgrade[0]?.[2], true);
  },
);

Deno.test('pre-pepper account, wrong password: ONE failure for two grants', async () => {
  const { deps, calls } = fake({ legacy: true, password: 'old dashboard pw 1' });
  const out = await signIn(body('denise', 'guess-guess-1'), null, deps);
  assertEquals([out.status, out.body.code], [401, 'WRONG']);
  assertEquals(calls.grant.length, 2);
  assertEquals(calls.failed.length, 1);
  assertEquals(calls.upgrade, []);
});

Deno.test(
  'upgrade failure never blocks the sign-in; legacy upgrade can be switched off',
  async () => {
    const flaky = fake({ legacy: true, password: 'old dashboard pw 1', upgradeThrows: true });
    const r = await signIn(body('denise', 'old dashboard pw 1'), null, flaky.deps);
    assertEquals([r.status, r.upgraded], [200, false]);
    const off = fake({ legacy: true, password: 'old dashboard pw 1', legacyUpgrade: false });
    const r2 = await signIn(body('denise', 'old dashboard pw 1'), null, off.deps);
    assertEquals([r2.status, r2.body.code], [401, 'WRONG']);
    assertEquals(off.calls.legacy, [], 'no lookup when switched off');
    const down = fake({ legacy: true, password: 'old dashboard pw 1', storeThrows: 'legacy' });
    const r3 = await signIn(body('denise', 'old dashboard pw 1'), null, down.deps);
    assertEquals([r3.status, r3.body.code], [503, 'INTERNAL']);
  },
);

Deno.test(
  'pre-pepper upgrade: a failed fresh sign-in after the upgrade is an error, not a dead session',
  async () => {
    let n = 0;
    const { deps } = fake({
      legacy: true,
      password: 'old dashboard pw 1',
      grant: (_email, pw) => {
        n += 1;
        if (n === 2 && pw === 'old dashboard pw 1') return { status: 200, body: SESSION };
        return { status: 400, body: { error_code: 'invalid_credentials' } };
      },
    });
    const out = await signIn(body('denise', 'old dashboard pw 1'), null, deps);
    assertEquals([out.status, out.body.code], [502, 'INTERNAL']);
  },
);

// ------------------------------------------------------------------------------------------------
// Shared plant iPad (owner 2026-11-10)

const deviceBody = (o: Record<string, unknown>) => JSON.stringify(o);

Deno.test('parseDeviceBody: the two device shapes; anything else is refused', () => {
  assertEquals(parseDeviceBody(deviceBody({ device_token: DEVICE })), {
    kind: 'people',
    token: DEVICE,
  });
  assertEquals(
    parseDeviceBody(
      deviceBody({
        device_token: DEVICE,
        member_id: DENISE_MEMBER.toUpperCase(),
        password: '483920',
      }),
    ),
    { kind: 'sign_in', token: DEVICE, memberId: DENISE_MEMBER, password: '483920' },
  );
  for (const o of [
    { device_token: 'short' },
    { device_token: DEVICE.toUpperCase() },
    { device_token: DEVICE, member_id: 'not-a-uuid', password: '1' },
    { device_token: DEVICE, member_id: DENISE_MEMBER, password: '' },
    { device_token: DEVICE, member_id: DENISE_MEMBER, password: 'x'.repeat(73) },
    { device_token: DEVICE, member_id: DENISE_MEMBER },
    { device_token: DEVICE, member_id: DENISE_MEMBER, password: '1', extra: 1 },
    { device_token: DEVICE, username: 'denise', password: '1' },
  ]) {
    assertEquals(parseDeviceBody(deviceBody(o)), null, JSON.stringify(o).slice(0, 60));
  }
});

Deno.test(
  'device people: a live device gets its names; any other token gets an empty list',
  async () => {
    const { deps } = fake();
    const live = await signIn(deviceBody({ device_token: DEVICE }), null, deps);
    assertEquals(live, { status: 200, body: { people: [{ id: DENISE_MEMBER, name: 'Denise' }] } });
    const other = await signIn(deviceBody({ device_token: 'cd'.repeat(32) }), null, deps);
    assertEquals(other, { status: 200, body: { people: [] } });
  },
);

Deno.test('device people: a store error fails closed (503)', async () => {
  const { deps } = fake({ storeThrows: 'device' });
  const r = await signIn(deviceBody({ device_token: DEVICE }), null, deps);
  assertEquals(r.status, 503);
});

Deno.test(
  'device sign-in: a listed person with the right password signs in through the same lockout',
  async () => {
    const { deps, calls } = fake();
    const r = await signIn(
      deviceBody({ device_token: DEVICE, member_id: DENISE_MEMBER, password: '483920' }),
      '203.0.113.9',
      deps,
    );
    assertEquals(r.status, 200);
    assertEquals(r.body.access_token, 'at');
    // Same lockout key as typing "denise" on any phone, and only the peppered password reaches GoTrue.
    assertEquals(calls.begin, [[DENISE, '203.0.113.9']]);
    assertEquals(calls.grant, [[DENISE, await pepperPassword(PEPPER, DENISE, '483920')]]);
  },
);

Deno.test('device sign-in: wrong passwords count against the same login and lock it', async () => {
  const { deps, calls } = fake();
  const send = (pw: string) =>
    signIn(
      deviceBody({ device_token: DEVICE, member_id: DENISE_MEMBER, password: pw }),
      null,
      deps,
    );
  for (let i = 0; i < 4; i++) assertEquals((await send('000000')).status, 401);
  assertEquals((await send('000000')).body.code, 'LOCKED');
  // Locked even with the right password, and the normal username sign-in is locked too.
  assertEquals((await send('483920')).body.code, 'LOCKED');
  assertEquals((await signIn(body('denise', '483920'), null, deps)).body.code, 'LOCKED');
  assertEquals(calls.failed.length, 5);
});

Deno.test(
  'device sign-in: an unknown device or an unlisted person is WRONG and never reaches GoTrue',
  async () => {
    const { deps, calls } = fake();
    for (const o of [
      { device_token: 'cd'.repeat(32), member_id: DENISE_MEMBER, password: '483920' },
      {
        device_token: DEVICE,
        member_id: '00000000-0000-4000-8000-000000000000',
        password: '483920',
      },
    ]) {
      const r = await signIn(deviceBody(o), null, deps);
      assertEquals(r.status, 401);
      assertEquals(r.body.code, 'WRONG');
    }
    assertEquals(calls.begin.length, 0);
    assertEquals(calls.grant.length, 0);
  },
);

Deno.test(
  'device sign-in: a store error fails closed (503) before any password check',
  async () => {
    const { deps, calls } = fake({ storeThrows: 'device' });
    const r = await signIn(
      deviceBody({ device_token: DEVICE, member_id: DENISE_MEMBER, password: '483920' }),
      null,
      deps,
    );
    assertEquals(r.status, 503);
    assertEquals(calls.grant.length, 0);
  },
);
