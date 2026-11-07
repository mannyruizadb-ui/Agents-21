// _shared/pepper.ts (used by sign-in and manage-users). Run with the sign-in tests in CI.
import { assertEquals, assertNotEquals, assertRejects, assertThrows } from '@std/assert';
import {
  PASSWORD_VERSION,
  pepperPassword,
  PepperMissingError,
  requirePepper,
} from '../_shared/pepper.ts';

const PEPPER = 'test-pepper-0123456789abcdef0123456789';
const DENISE = 'denise@accounts.adbheadquarters.com';

Deno.test(
  'known answer: base64url(HMAC-SHA256(pepper, lower(login) || 0x00 || typed))',
  async () => {
    // Computed independently (Python hmac/hashlib).
    assertEquals(
      await pepperPassword(PEPPER, DENISE, '483920'),
      '1_AmqnJi_9_uLNww26VjsRlk7FKHX1JiQcowFwuAdQ0',
    );
  },
);

Deno.test("43 URL-safe characters (under bcrypt's 72 bytes); deterministic", async () => {
  const a = await pepperPassword(PEPPER, DENISE, '483920');
  assertEquals(a.length, 43);
  assertEquals(/^[A-Za-z0-9_-]{43}$/.test(a), true);
  assertEquals(await pepperPassword(PEPPER, DENISE, '483920'), a);
});

Deno.test(
  'the login is normalised (trim + lowercase) and mixed in; the typed value is not',
  async () => {
    const a = await pepperPassword(PEPPER, DENISE, '483920');
    assertEquals(
      await pepperPassword(PEPPER, ' Denise@Accounts.ADBheadquarters.com ', '483920'),
      a,
    );
    assertNotEquals(
      await pepperPassword(PEPPER, 'maria@accounts.adbheadquarters.com', '483920'),
      a,
    );
    assertNotEquals(await pepperPassword(PEPPER, DENISE, '483921'), a);
    assertNotEquals(
      await pepperPassword(PEPPER, DENISE, ' 483920'),
      a,
      'the password is used exactly as typed',
    );
    // The 0x00 separator: ("ab", "c") and ("a", "bc") never collide.
    assertNotEquals(
      await pepperPassword(PEPPER, 'ab', 'c'),
      await pepperPassword(PEPPER, 'a', 'bc'),
    );
    assertNotEquals(
      await pepperPassword(`${PEPPER}x`, DENISE, '483920'),
      a,
      'another pepper, another value',
    );
  },
);

Deno.test('missing or short pepper: fail closed', async () => {
  for (const bad of [undefined, null, '', 'x'.repeat(31)]) {
    assertThrows(() => requirePepper(bad), PepperMissingError);
  }
  assertEquals(requirePepper('x'.repeat(32)), 'x'.repeat(32));
  await assertRejects(() => pepperPassword('short', DENISE, '483920'), PepperMissingError);
  assertEquals(PASSWORD_VERSION, 2);
});
