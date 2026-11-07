// Password rules for instant feedback in the app (owner-approved 2026-11-06; owner 2026-11-07: the
// same rule for every account). KEEP IN SYNC with supabase/functions/_shared/passwordRules.ts (the
// server decides; this copy only gives feedback before sending). src/lib/passwordRules.test.ts checks
// that both copies give the same answers.
//
// * EITHER exactly 6 digits that are not a simple pattern, OR at least 10 characters.
// * At most 72 bytes (bcrypt ignores the rest).
//
// Simple 6-digit patterns: one digit repeated; a straight run up or down (with wrap-around); a 3-digit
// block twice; a 2-digit block three times; three doubled digits; a mirrored half.

export const PASSWORD_MIN_CHARS = 10;
export const PASSWORD_MAX_BYTES = 72;
export const PIN_PASSWORD_DIGITS = 6;

export type PasswordProblem = 'password_too_short' | 'password_too_long' | 'password_too_simple';

const SIX_DIGITS = /^[0-9]{6}$/;

/** True for a 6-digit password that matches one of the simple patterns above. */
export function isSimpleSixDigits(pw: string): boolean {
  if (!SIX_DIGITS.test(pw)) return false;
  const d = [...pw].map(Number);
  const steps = d.slice(1).map((x, i) => (x - (d[i] ?? 0) + 10) % 10);
  const run = steps.every((s) => s === 1) || steps.every((s) => s === 9);
  return (
    /^(\d)\1{5}$/.test(pw) ||
    run ||
    /^(\d{3})\1$/.test(pw) ||
    /^(\d{2})\1\1$/.test(pw) ||
    /^(\d)\1(\d)\2(\d)\3$/.test(pw) ||
    /^(\d)(\d)(\d)\3\2\1$/.test(pw)
  );
}

/** The first rule the password breaks, or null when it is acceptable. */
export function passwordProblem(pw: string): PasswordProblem | null {
  if (new TextEncoder().encode(pw).length > PASSWORD_MAX_BYTES) return 'password_too_long';
  if (SIX_DIGITS.test(pw)) return isSimpleSixDigits(pw) ? 'password_too_simple' : null;
  return [...pw].length < PASSWORD_MIN_CHARS ? 'password_too_short' : null;
}

/** The locale key under `password.problems` for a server or local problem code. */
export function passwordProblemKey(problem: PasswordProblem): 'tooShort' | 'tooLong' | 'tooSimple' {
  return problem === 'password_too_long'
    ? 'tooLong'
    : problem === 'password_too_simple'
      ? 'tooSimple'
      : 'tooShort';
}

export function isPasswordProblem(v: unknown): v is PasswordProblem {
  return v === 'password_too_short' || v === 'password_too_long' || v === 'password_too_simple';
}
