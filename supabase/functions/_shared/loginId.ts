// Login identity rule (owner decision 2026-11-03, PRD A4).
//
// People sign in with a USERNAME, not an email. Supabase Auth needs an email, so a username maps
// to `<username>@accounts.adbheadquarters.com`. The owner controls that domain and it has no
// mailbox, so nothing can ever be delivered there. A typed value containing `@` is used as-is:
// REQUIRED, because the owner's own account (created in the Supabase dashboard) uses a real email,
// which the owner types into the same "Username" field. The UI never says "email" (owner rule
// 2026-11-03). Managers and everyone else get username-only accounts from the People screen.
//
// KEEP IN SYNC with src/lib/loginId.ts (this Edge Function copy cannot import from src/;
// the deployed bundle holds only supabase/functions). src/lib/loginId.test.ts runs the same cases
// against both copies, and manage-users/validation_test.ts tests this copy under Deno.

export const LOGIN_EMAIL_DOMAIN = 'accounts.adbheadquarters.com';

/** Lowercase a-z, 0-9, dot, underscore, hyphen; 3–32 chars. */
export const USERNAME_PATTERN = /^[a-z0-9._-]{3,32}$/;

export function isValidUsername(value: string): boolean {
  return USERNAME_PATTERN.test(value);
}

/**
 * Turns what the person typed into the email Supabase Auth expects.
 * Returns null when the value is neither an email nor a valid username.
 */
export function toLoginEmail(typed: string): string | null {
  const value = typed.trim().toLowerCase();
  if (value.includes('@')) return value.length >= 3 && value.length <= 254 ? value : null;
  return isValidUsername(value) ? `${value}@${LOGIN_EMAIL_DOMAIN}` : null;
}

/**
 * The username for a mapped auth email, or null for any other email. The UI shows usernames only
 * (owner rule 2026-11-03: the word "email" and email addresses never appear in the UI).
 */
export function usernameFromEmail(email: string): string | null {
  const suffix = `@${LOGIN_EMAIL_DOMAIN}`;
  const lower = email.toLowerCase();
  if (!lower.endsWith(suffix)) return null;
  const username = lower.slice(0, -suffix.length);
  return isValidUsername(username) ? username : null;
}
