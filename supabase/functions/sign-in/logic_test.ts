import { assert, assertEquals, assertFalse } from '@std/assert';
import {
  clientIp,
  type FailResult,
  type GateResult,
  type GrantResult,
  parseBody,
  pickSession,
  signIn,
  type SignInDeps,
} from './logic.ts';

const SESSION = {
  access_token: 'at',
  refresh_token: 'rt',
  expires_in: 3600,
  expires_at: 1_800_000_000,
  token_type: 'bearer',
  user: { id: 'u1', email: 'denise@accounts.adbheadquarters.com', app_metadata: {} },
  weak_password: null,
};

interface Calls {
  begin: [string, string | null][];
  failed: [string, string | null][];
  succeeded: [string, string | null][];
  grant: [string, string][];
}

/** A fake lockout store (5 failures lock, like the DB) and a fake GoTrue with one known account. */
function fake(
  opts: {
    password?: string;
    grant?: (email: string, pw: string) => GrantResult | Promise<GrantResult>;
    gate?: GateResult;
    fail?: FailResult;
    storeThrows?: 'begin' | 'failed' | 'succeeded';
  } = {},
) {
  const calls: Calls = { begin: [], failed: [], succeeded: [], grant: [] };
  const failures = new Map<string, number>();
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
      return email === 'denise@accounts.adbheadquarters.com' && pw === (opts.password ?? '483920')
        ? { status: 200, body: SESSION }
        : {
            status: 400,
            body: { error_code: 'invalid_credentials', msg: 'Invalid login credentials' },
          };
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
  assertEquals(calls.begin, [['denise@accounts.adbheadquarters.com', '198.51.100.7']]);
  assertEquals(calls.succeeded, [['denise@accounts.adbheadquarters.com', '198.51.100.7']]);
  assertEquals(calls.failed, []);
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

Deno.test('clientIp: platform headers, first forwarded address, junk ignored', () => {
  assertEquals(
    clientIp(new Headers({ 'cf-connecting-ip': '203.0.113.9', 'x-forwarded-for': '1.1.1.1' })),
    '203.0.113.9',
  );
  assertEquals(
    clientIp(new Headers({ 'x-forwarded-for': ' 198.51.100.7 , 10.0.0.1' })),
    '198.51.100.7',
  );
  assertEquals(clientIp(new Headers({ 'x-real-ip': '2001:db8::1' })), '2001:db8::1');
  assertEquals(clientIp(new Headers({ 'x-forwarded-for': '<script>' })), null);
  assertEquals(clientIp(new Headers()), null);
});
