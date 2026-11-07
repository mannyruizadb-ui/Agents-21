import { assert, assertEquals } from '@std/assert';
import {
  isSimpleSixDigits,
  isSixDigitPassword,
  PASSWORD_MAX_BYTES,
  passwordProblem,
} from '../_shared/passwordRules.ts';

Deno.test(
  '6 digits: allowed for every account (owners too, 2026-11-07) when not a simple pattern',
  () => {
    for (const pw of ['483920', '205817', '730164', '019283', '564738']) {
      assertEquals(passwordProblem(pw), null, pw);
      assert(isSixDigitPassword(pw));
    }
    assertEquals(passwordProblem('correct horse'), null);
    assertEquals(passwordProblem('a'.repeat(9)), 'password_too_short');
  },
);

Deno.test('simple 6-digit patterns are refused (all six documented rules)', () => {
  const simple = [
    // 1. one digit repeated
    '000000',
    '111111',
    '555555',
    '999999',
    // 2. straight runs up / down, with wrap-around
    '012345',
    '123456',
    '456789',
    '567890',
    '789012',
    '901234',
    '987654',
    '654321',
    '543210',
    '432109',
    '109876',
    '098765',
    // 3. a 3-digit block twice
    '123123',
    '147147',
    '908908',
    // 4. a 2-digit block three times
    '121212',
    '696969',
    '101010',
    // 5. three doubled digits
    '112233',
    '998877',
    '001122',
    '447799',
    // 6. mirrored half
    '123321',
    '112211',
    '900009',
    '258852',
  ];
  for (const pw of simple) {
    assert(isSimpleSixDigits(pw), pw);
    assertEquals(passwordProblem(pw), 'password_too_simple', pw);
  }
});

Deno.test('near misses of the patterns are allowed', () => {
  for (const pw of [
    '123457',
    '124356',
    '111112',
    '123124',
    '121213',
    '112234',
    '123320',
    '135792',
  ]) {
    assertEquals(isSimpleSixDigits(pw), false, pw);
    assertEquals(passwordProblem(pw), null, pw);
  }
});

Deno.test('the refused list stays small: 2,910 of the 1,000,000 six-digit values (0.3 %)', () => {
  let n = 0;
  for (let i = 0; i < 1_000_000; i++) if (isSimpleSixDigits(String(i).padStart(6, '0'))) n++;
  assertEquals(n, 2910);
});

Deno.test('other lengths: 7–9 characters and 6 non-digits are too short; ≥ 10 is fine', () => {
  for (const pw of [
    '',
    '1',
    '12345',
    '1234567',
    '12345678',
    '123456789',
    'abcdef',
    'abc123',
    '12345 ',
    ' 12345',
  ]) {
    assertEquals(passwordProblem(pw), 'password_too_short', JSON.stringify(pw));
  }
  for (const pw of ['1234567890', 'a'.repeat(10), 'Lavadora-4!']) {
    assertEquals(passwordProblem(pw), null, pw);
  }
  // Full-width or Arabic-Indic digits are not the ASCII digits of the number pad.
  assertEquals(passwordProblem('４８３９２０'), 'password_too_short');
});

Deno.test('at most 72 bytes (bcrypt) for everyone', () => {
  assertEquals(passwordProblem('a'.repeat(PASSWORD_MAX_BYTES)), null);
  assertEquals(passwordProblem('a'.repeat(PASSWORD_MAX_BYTES + 1)), 'password_too_long');
  assertEquals(passwordProblem('€'.repeat(25)), 'password_too_long');
});
