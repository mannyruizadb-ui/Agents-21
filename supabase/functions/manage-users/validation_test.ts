import { assert, assertEquals, assertMatch, assertNotEquals } from '@std/assert';
import {
  isValidEmail,
  isValidUsername,
  toLoginEmail,
  usernameFromEmail,
} from '../_shared/loginId.ts';
import { corsHeaders, parseAllowedOrigins } from '../_shared/cors.ts';
import { generateTempPassword, parseRequest, TEMP_PASSWORD_ALPHABET } from './validation.ts';

const PLANT = '00000000-0000-0000-0000-0000000000a1';
const USER = '00000000-0000-0000-0000-0000000000b2';
const base = {
  action: 'create',
  plant_id: PLANT,
  username: 'maria',
  display_name: 'María',
  role: 'lead',
};

Deno.test('loginId (Edge copy): username mapping and bounds', () => {
  assertEquals(toLoginEmail(' Maria '), 'maria@accounts.adbheadquarters.com');
  assertEquals(toLoginEmail('Owner@Example.com'), 'owner@example.com');
  // Owner's real-email account, typed in full into the Username field.
  assertEquals(toLoginEmail(' Owner.Name@Example.COM '), 'owner.name@example.com');
  assertEquals(toLoginEmail('ab'), null);
  assertEquals(isValidUsername('a'.repeat(32)), true);
  assertEquals(isValidUsername('a'.repeat(33)), false);
  assertEquals(usernameFromEmail('maria@accounts.adbheadquarters.com'), 'maria');
  assertEquals(usernameFromEmail('owner@example.com'), null);
  // Owner account created in the dashboard as <username>@accounts.adbheadquarters.com.
  assertEquals(toLoginEmail('  Manny '), 'manny@accounts.adbheadquarters.com');
});

Deno.test('create: valid input passes; can_manage_staff defaults to false', () => {
  const r = parseRequest(base);
  assert(r.ok);
  if (r.ok && r.value.action === 'create') assertEquals(r.value.can_manage_staff, false);
});

Deno.test('create: display name is trimmed', () => {
  const r = parseRequest({ ...base, display_name: '  Ana  ' });
  assert(r.ok && r.value.action === 'create' && r.value.display_name === 'Ana');
});

Deno.test('create: rejects bad usernames, roles, names and extra fields', () => {
  for (const bad of [
    { ...base, username: 'Maria' },
    { ...base, username: 'maria@x.com' },
    { ...base, username: 'ab' },
    { ...base, role: 'display' },
    { ...base, role: 'superuser' },
    { ...base, display_name: '   ' },
    { ...base, display_name: 'a\u0007b' },
    { ...base, display_name: 'x'.repeat(81) },
    { ...base, plant_id: 'not-a-uuid' },
    { ...base, org_id: PLANT },
    { ...base, plant_id: null },
  ]) {
    const r = parseRequest(bad);
    assert(!r.ok, JSON.stringify(bad));
  }
});

Deno.test('create: can_manage_staff only with role manager', () => {
  assert(parseRequest({ ...base, role: 'manager', can_manage_staff: true }).ok);
  for (const role of ['owner', 'lead', 'viewer']) {
    const r = parseRequest({ ...base, role, can_manage_staff: true });
    assert(!r.ok);
    if (!r.ok) assertEquals(r.fields, ['can_manage_staff']);
  }
});

Deno.test('target actions need plant_id and user_id', () => {
  for (const action of ['reset_password', 'deactivate', 'unlock']) {
    assert(parseRequest({ action, plant_id: PLANT, user_id: USER }).ok);
    assert(!parseRequest({ action, plant_id: PLANT }).ok);
    assert(!parseRequest({ action, user_id: USER }).ok);
  }
  assert(parseRequest({ action: 'list', plant_id: PLANT }).ok);
  assert(!parseRequest({ action: 'nope', plant_id: PLANT }).ok);
  assert(!parseRequest(null).ok);
  assert(!parseRequest('create').ok);
});

Deno.test('change_own_password: 10 chars min, 72 bytes max, reasons reported', () => {
  assert(
    parseRequest({
      action: 'change_own_password',
      current_password: 'old-pass',
      new_password: 'a'.repeat(10),
    }).ok,
  );
  assert(
    parseRequest({
      action: 'change_own_password',
      current_password: 'old-pass',
      new_password: 'a'.repeat(72),
    }).ok,
  );
  const short = parseRequest({
    action: 'change_own_password',
    current_password: 'old-pass',
    new_password: 'a'.repeat(9),
  });
  assert(!short.ok && short.reason === 'password_too_short');
  const long = parseRequest({
    action: 'change_own_password',
    current_password: 'old-pass',
    new_password: 'a'.repeat(73),
  });
  assert(!long.ok && long.reason === 'password_too_long');
  // 25 × 3-byte chars = 75 bytes: too long even though only 25 characters.
  const multibyte = parseRequest({
    action: 'change_own_password',
    current_password: 'old-pass',
    new_password: '€'.repeat(25),
  });
  assert(!multibyte.ok && multibyte.reason === 'password_too_long');
});

Deno.test('validation errors never echo values', () => {
  const r = parseRequest({
    action: 'change_own_password',
    current_password: 'old-pass',
    new_password: 'secret',
  });
  assert(!r.ok);
  assert(!JSON.stringify(r).includes('secret'));
});

Deno.test('temp password: 19 chars, 4 groups of 4, unambiguous alphabet, random', () => {
  const seen = new Set<string>();
  for (let i = 0; i < 200; i++) {
    const p = generateTempPassword();
    assertMatch(p, /^[A-Za-z2-9]{4}(-[A-Za-z2-9]{4}){3}$/);
    assert(p.length >= 14);
    for (const ch of p.replaceAll('-', '')) assert(TEMP_PASSWORD_ALPHABET.includes(ch), ch);
    assert(!/[IOlo01]/.test(p));
    seen.add(p);
  }
  assertEquals(seen.size, 200);
});

Deno.test('temp password: rejection sampling skips biased bytes', () => {
  // 255 is above the 224 limit for a 56-symbol alphabet and must be skipped.
  let call = 0;
  const p = generateTempPassword((b) => {
    b.fill(call++ === 0 ? 255 : 0);
    return b;
  });
  assertEquals(p, 'AAAA-AAAA-AAAA-AAAA');
});

Deno.test('cors: only listed origins are echoed', () => {
  const allowed = parseAllowedOrigins('https://a.example, https://b.example');
  assertEquals(
    corsHeaders('https://a.example', allowed)['Access-Control-Allow-Origin'],
    'https://a.example',
  );
  assertEquals(
    corsHeaders('https://evil.example', allowed)['Access-Control-Allow-Origin'],
    undefined,
  );
  assertEquals(corsHeaders(null, allowed)['Access-Control-Allow-Origin'], undefined);
  assertNotEquals(corsHeaders('https://a.example', allowed)['Access-Control-Allow-Origin'], '*');
  assertEquals(parseAllowedOrigins(undefined), ['http://127.0.0.1:5173', 'http://localhost:5173']);
});

Deno.test(
  'change_own_password: 6 digits that are not a simple pattern are accepted at parse',
  () => {
    assert(
      parseRequest({
        action: 'change_own_password',
        current_password: 'old-pass',
        new_password: '483920',
      }).ok,
    );
    const simple = parseRequest({
      action: 'change_own_password',
      current_password: 'old-pass',
      new_password: '123456',
    });
    assert(!simple.ok && simple.reason === 'password_too_simple');
    const seven = parseRequest({
      action: 'change_own_password',
      current_password: 'old-pass',
      new_password: '4839201',
    });
    assert(!seven.ok && seven.reason === 'password_too_short');
    const letters = parseRequest({
      action: 'change_own_password',
      current_password: 'old-pass',
      new_password: 'abcdef',
    });
    assert(!letters.ok && letters.reason === 'password_too_short');
    const notString = parseRequest({
      action: 'change_own_password',
      current_password: 'old-pass',
      new_password: 483920,
    });
    assert(!notString.ok && notString.reason === 'password_invalid');
  },
);

Deno.test('create / reset_password: optional owner-chosen password, same rules', () => {
  assert(parseRequest({ ...base, role: 'manager', password: '483920' }).ok);
  const simple = parseRequest({ ...base, role: 'manager', password: '111111' });
  assert(!simple.ok && simple.reason === 'password_too_simple');
  if (!simple.ok) assertEquals(simple.fields, ['password']);
  // Owners may use 6 digits too (owner decision 2026-11-07).
  assert(parseRequest({ ...base, role: 'owner', password: '483920' }).ok);
  assert(parseRequest({ ...base, role: 'owner', password: 'a-long-pass' }).ok);
  assert(
    parseRequest({ action: 'reset_password', plant_id: PLANT, user_id: USER, password: '483920' })
      .ok,
  );
  const r = parseRequest({
    action: 'reset_password',
    plant_id: PLANT,
    user_id: USER,
    password: '654321',
  });
  assert(!r.ok && r.reason === 'password_too_simple');
  assert(!JSON.stringify(r).includes('654321'));
  assert(
    !parseRequest({ action: 'deactivate', plant_id: PLANT, user_id: USER, password: '483920' }).ok,
  );
  assert(
    !parseRequest({ action: 'unlock', plant_id: PLANT, user_id: USER, password: '483920' }).ok,
  );
});

Deno.test(
  'change_own_password: the current password is required (any old one; only its size is checked)',
  () => {
    const missing = parseRequest({ action: 'change_own_password', new_password: '483920' });
    assert(!missing.ok);
    if (!missing.ok) {
      assertEquals(missing.fields, ['current_password']);
      assertEquals(missing.reason, undefined, 'no password-rule reason for the current password');
    }
    // An old password that breaks today's rules is still accepted as the CURRENT one.
    assert(
      parseRequest({ action: 'change_own_password', current_password: '1', new_password: '483920' })
        .ok,
    );
    for (const bad of ['', 'a'.repeat(73), 7]) {
      const r = parseRequest({
        action: 'change_own_password',
        current_password: bad,
        new_password: '483920',
      });
      assert(!r.ok);
      if (!r.ok) assertEquals(r.fields, ['current_password']);
    }
    const echo = parseRequest({
      action: 'change_own_password',
      current_password: 'top-secret-1',
      new_password: 'x',
    });
    assert(!JSON.stringify(echo).includes('top-secret-1'));
  },
);

Deno.test(
  'loginId (Edge copy): "@" logins must be strict ASCII emails (security review L4)',
  () => {
    for (const ok of [
      'mannyruiz.adb@gmail.com',
      'owner+plant@example.co',
      'a@b.cd',
      'maria@accounts.adbheadquarters.com',
    ]) {
      assert(isValidEmail(ok), ok);
      assertEquals(toLoginEmail(` ${ok.toUpperCase()} `), ok);
    }
    for (const bad of [
      'a@b',
      '@example.com',
      'owner@',
      '.owner@example.com',
      'owner.@example.com',
      'ow..ner@example.com',
      'owner@-example.com',
      'owner@example-.com',
      'owner@example..com',
      'owner@example.c',
      'owner@example.123',
      'o wner@example.com',
      'owner@exa mple.com',
      '"owner"@example.com',
      'owner@[127.0.0.1]',
      'josé@example.com',
      'owner@exämple.com',
      'a@b@example.com',
      `${'a'.repeat(65)}@example.com`,
      `owner@${'a'.repeat(250)}.com`,
    ]) {
      assertEquals(toLoginEmail(bad), null, bad);
    }
  },
);
