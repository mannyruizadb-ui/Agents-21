import { describe, expect, it } from 'vitest';
import * as app from './passwordRules';
// The server's copy (it cannot import from src/). Same answers, both copies.
import * as edge from '../../supabase/functions/_shared/passwordRules';

describe.each([
  ['src/lib/passwordRules', app],
  ['supabase/functions/_shared/passwordRules', edge],
])('%s', (_name, m) => {
  it('accepts 6 digits that are not a simple pattern', () => {
    for (const ok of ['385102', '472918', '090807', '135792']) {
      expect(m.passwordProblem(ok)).toBeNull();
    }
  });

  it('refuses the simple 6-digit patterns', () => {
    for (const bad of [
      '000000',
      '777777',
      '123456',
      '890123',
      '987654',
      '109876',
      '123123',
      '121212',
      '112233',
      '123321',
    ]) {
      expect(m.passwordProblem(bad)).toBe('password_too_simple');
    }
  });

  it('refuses 7–9 characters and short non-digit passwords', () => {
    for (const bad of ['1234567', '12345678', 'abcdefghi', 'abc123', '12345', '']) {
      expect(m.passwordProblem(bad)).toBe('password_too_short');
    }
  });

  it('accepts 10 or more characters, up to 72 bytes', () => {
    expect(m.passwordProblem('abcdefghij')).toBeNull();
    expect(m.passwordProblem('a'.repeat(72))).toBeNull();
    expect(m.passwordProblem('a'.repeat(73))).toBe('password_too_long');
    // Bytes, not characters: 37 two-byte letters = 74 bytes.
    expect(m.passwordProblem('ñ'.repeat(37))).toBe('password_too_long');
  });
});

it('both copies agree on every 6-digit value', () => {
  let simple = 0;
  for (let n = 0; n < 1_000_000; n++) {
    const pw = String(n).padStart(6, '0');
    const a = app.isSimpleSixDigits(pw);
    if (a !== edge.isSimpleSixDigits(pw)) throw new Error(`copies disagree on ${pw}`);
    if (a) simple++;
  }
  expect(simple).toBe(2910);
});

it('maps problems to locale keys', () => {
  expect(app.passwordProblemKey('password_too_short')).toBe('tooShort');
  expect(app.passwordProblemKey('password_too_long')).toBe('tooLong');
  expect(app.passwordProblemKey('password_too_simple')).toBe('tooSimple');
  expect(app.isPasswordProblem('password_too_simple')).toBe(true);
  expect(app.isPasswordProblem('same_password')).toBe(false);
});
