// Password pepper (owner-approved 2026-11-07; security review 2026-11-07 BLOCK H1).
//
// Why: GoTrue's /auth/v1/token is reachable directly with the publishable key, around the sign-in
// function's lockout, and Supabase Pro has no password-verification hook. With 6-digit passwords that
// would allow brute force at GoTrue's per-IP rate limit from many IPs. So the password GoTrue stores is
// never what the person types. It is:
//
//     base64url( HMAC-SHA256( key = SIGN_IN_PEPPER, msg = lower(login) || 0x00 || typed ) )
//
// (43 ASCII characters, under bcrypt's 72-byte limit). Only the sign-in and manage-users Edge Functions
// know SIGN_IN_PEPPER (a function secret), so a guess sent straight to GoTrue is a guess at a 256-bit
// value. The login (the normalised auth email) is mixed in so two accounts with the same 6 digits never
// share a stored value. Password RULES are checked on the TYPED value (passwordRules.ts), never on this.
//
// Consequences (documented for the owner/meta in the HANDOFF):
//   * Rotating SIGN_IN_PEPPER invalidates every stored password: everyone needs a reset.
//   * Accounts whose password was set before the pepper (app_metadata.pw_v is not 2, e.g. the owner's
//     dashboard-set one) are upgraded on their next successful sign-in (sign-in/logic.ts), or by a reset.
//   * Missing or short pepper: fail closed (PepperMissingError); nothing is sent to GoTrue.
//
// Pure module: no env (callers pass the pepper), Web Crypto only.

/** Stored-password version written to app_metadata.pw_v by every peppered write. */
export const PASSWORD_VERSION = 2;
/** A pepper shorter than this is refused (deploy-db generates 64 hex characters). */
export const PEPPER_MIN_CHARS = 32;

export class PepperMissingError extends Error {
  constructor() {
    super('SIGN_IN_PEPPER is not configured');
    this.name = 'PepperMissingError';
  }
}

/** The configured pepper, or PepperMissingError when it is missing or too short (fail closed). */
export function requirePepper(value: string | undefined | null): string {
  if (typeof value !== 'string' || value.length < PEPPER_MIN_CHARS) throw new PepperMissingError();
  return value;
}

function base64url(bytes: Uint8Array): string {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/**
 * The password to store in / send to GoTrue for `login` (the normalised auth email; lowercased here
 * too) and what the person typed. Deterministic; never logged.
 */
export async function pepperPassword(
  pepper: string,
  login: string,
  typed: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(requirePepper(pepper)),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const loginBytes = new TextEncoder().encode(login.trim().toLowerCase());
  const typedBytes = new TextEncoder().encode(typed);
  const msg = new Uint8Array(loginBytes.length + 1 + typedBytes.length);
  msg.set(loginBytes, 0);
  msg[loginBytes.length] = 0;
  msg.set(typedBytes, loginBytes.length + 1);
  return base64url(new Uint8Array(await crypto.subtle.sign('HMAC', key, msg)));
}
