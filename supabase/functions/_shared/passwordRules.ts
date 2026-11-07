// Password rules (owner-approved 2026-11-06: 6-digit sign-in, with lockout; owner decision 2026-11-07:
// the same rule for EVERY account, owners included — "keep it simple").
//
// * Every account: EITHER exactly 6 digits that are not an obvious pattern, OR at least 10 characters
//   (as before). 7–9 characters, and 6 characters that are not all digits, are refused.
// * Everyone: at most 72 bytes (Supabase Auth hashes with bcrypt, which ignores the rest).
//
// A 6-digit password has 10^6 values; it is only acceptable because the `sign-in` Edge Function
// locks a login after 5 wrong passwords in 15 minutes (5 guesses per 15 minutes ≈ 480 per day,
// before the owner is alerted on the first lock). The obvious patterns below are the ones people pick
// first; refusing them removes 2,910 of the 1,000,000 values (0.3 %; see passwordRules_test.ts), small enough to
// keep the rule easy to explain ("not a simple pattern").
//
// Simple patterns (6 digits), documented and kept small on purpose:
//   1. one digit repeated              000000, 111111 … 999999
//   2. a straight run up or down,      012345, 123456 … 456789, 567890, 678901, 789012, 890123,
//      with wrap-around (step ±1)      901234; 987654 … 543210, 432109, 321098, 210987, 109876, 098765
//   3. a 3-digit block twice           123123, 147147, 000000
//   4. a 2-digit block three times     121212, 696969, 101010
//   5. three doubled digits            112233, 998877, 001122
//   6. a mirrored half (palindrome)    123321, 112211, 900009
//
// Pure module (no env, no network): used by manage-users, tested by passwordRules_test.ts. The app's
// own copy of these rules (for instant feedback) must give the same answers; the server decides.

export const PASSWORD_MIN_CHARS = 10;
export const PASSWORD_MAX_BYTES = 72;
export const PIN_PASSWORD_DIGITS = 6;

export type PasswordProblem = 'password_too_short' | 'password_too_long' | 'password_too_simple';

const SIX_DIGITS = /^[0-9]{6}$/;

/** True for a 6-digit password that matches one of the six simple patterns above. */
export function isSimpleSixDigits(pw: string): boolean {
  if (!SIX_DIGITS.test(pw)) return false;
  const d = [...pw].map(Number);
  const steps = d.slice(1).map((x, i) => (x - d[i] + 10) % 10);
  const run = steps.every((s) => s === 1) || steps.every((s) => s === 9);
  return (
    /^(\d)\1{5}$/.test(pw) || // 1. one digit repeated
    run || // 2. straight run up or down (wrap-around)
    /^(\d{3})\1$/.test(pw) || // 3. 3-digit block twice
    /^(\d{2})\1\1$/.test(pw) || // 4. 2-digit block three times
    /^(\d)\1(\d)\2(\d)\3$/.test(pw) || // 5. three doubled digits
    /^(\d)(\d)(\d)\3\2\1$/.test(pw) // 6. mirrored half
  );
}

/** True when the password is a 6-digit PIN-style password. */
export function isSixDigitPassword(pw: string): boolean {
  return SIX_DIGITS.test(pw);
}

/** The first rule the password breaks, or null when it is acceptable (same rule for every account). */
export function passwordProblem(pw: string): PasswordProblem | null {
  if (new TextEncoder().encode(pw).length > PASSWORD_MAX_BYTES) return 'password_too_long';
  if (SIX_DIGITS.test(pw)) return isSimpleSixDigits(pw) ? 'password_too_simple' : null;
  return [...pw].length < PASSWORD_MIN_CHARS ? 'password_too_short' : null;
}
