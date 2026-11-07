// Pure decision logic for the sign-in Edge Function (owner-approved 2026-11-06: 6-digit passwords for
// managers, with lockout). No env, no network: index.ts passes the real lockout RPCs and GoTrue call,
// logic_test.ts passes fakes.
//
// Flow for {username, password}:
//   1. body: JSON object ≤ 2 KB with exactly `username` (what the person typed: a username, or an
//      email for the owner's own account) and `password` (1–72 bytes). Else 400 VALIDATION_FAILED.
//   2. login = toLoginEmail(username) (same rule as the app); a value that is neither a username nor an
//      email is still counted under its trimmed, lowercased form, and is "wrong" without asking GoTrue.
//   3. sign_in_begin(login, ip): while the login or the IP is locked → 429 {code: LOCKED,
//      retry_after_seconds}. The same answer for known and unknown logins.
//   4. GoTrue password grant. 200 → sign_in_succeeded, return the session (access_token,
//      refresh_token, expires_in, expires_at, token_type, user) for supabase.auth.setSession.
//      400 (wrong password, unknown user, banned user, …) → sign_in_failed: 401 {code: WRONG}, or 429
//      LOCKED when this failure locked the login. Same shape for unknown logins.
//      429 from GoTrue → 429 {code: RATE_LIMITED}; anything else → 502 {code: INTERNAL}.
//   5. Any lockout-store error → 503 INTERNAL: never call GoTrue without the lockout check (fail closed).
//
// Nothing here logs; index.ts logs only status codes (never usernames, passwords, tokens or bodies).
import { toLoginEmail } from '../_shared/loginId.ts';

export const MAX_BODY_BYTES = 2048;
export const MAX_PASSWORD_BYTES = 72;
const MAX_LOGIN_CHARS = 254;

export interface GateResult {
  allowed: boolean;
  retry_after_seconds: number;
}
export interface FailResult {
  locked: boolean;
  retry_after_seconds: number;
}
export interface GrantResult {
  status: number;
  body: unknown;
}

export interface SignInDeps {
  begin(login: string, ip: string | null): Promise<GateResult>;
  failed(login: string, ip: string | null): Promise<FailResult>;
  succeeded(login: string, ip: string | null): Promise<void>;
  /** POST /auth/v1/token?grant_type=password. Throws on a network error. */
  passwordGrant(email: string, password: string): Promise<GrantResult>;
}

export type Code = 'VALIDATION_FAILED' | 'LOCKED' | 'WRONG' | 'RATE_LIMITED' | 'INTERNAL';
export interface Outcome {
  status: number;
  body: Record<string, unknown>;
}

const MESSAGES: Record<Code, string> = {
  VALIDATION_FAILED: 'Type your username and password.',
  LOCKED: 'Too many wrong passwords. Try again later or ask the owner to unlock you.',
  WRONG: 'Wrong username or password.',
  RATE_LIMITED: 'Too many sign-ins right now. Try again in a minute.',
  INTERNAL: 'Could not sign in right now. Try again.',
};

function fail(status: number, code: Code, extra: Record<string, unknown> = {}): Outcome {
  return { status, body: { code, message: MESSAGES[code], ...extra } };
}

const locked = (seconds: number) =>
  fail(429, 'LOCKED', { retry_after_seconds: Math.max(1, Math.ceil(seconds)) });

export interface Credentials {
  /** Normalised login: the auth email, or the trimmed lowercased typed value when it is neither. */
  login: string;
  /** The email to send to GoTrue; null when the typed value is not a valid username or email. */
  email: string | null;
  password: string;
}

/** Parses the raw body. Values are never echoed in errors. */
export function parseBody(raw: string): Credentials | null {
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) return null;
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    return null;
  }
  if (body === null || typeof body !== 'object' || Array.isArray(body)) return null;
  const keys = Object.keys(body);
  if (keys.length !== 2 || !keys.includes('username') || !keys.includes('password')) return null;
  const { username, password } = body as { username: unknown; password: unknown };
  if (typeof username !== 'string' || typeof password !== 'string') return null;
  const typed = username.trim().toLowerCase();
  if (typed.length === 0 || typed.length > MAX_LOGIN_CHARS) return null;
  const pwBytes = new TextEncoder().encode(password).length;
  if (pwBytes === 0 || pwBytes > MAX_PASSWORD_BYTES) return null;
  const email = toLoginEmail(username);
  return { login: email ?? typed, email, password };
}

const SESSION_KEYS = [
  'access_token',
  'refresh_token',
  'expires_in',
  'expires_at',
  'token_type',
  'user',
] as const;

/** The session fields the client needs for supabase.auth.setSession; null when they are missing. */
export function pickSession(body: unknown): Record<string, unknown> | null {
  if (body === null || typeof body !== 'object') return null;
  const b = body as Record<string, unknown>;
  if (typeof b.access_token !== 'string' || typeof b.refresh_token !== 'string') return null;
  const out: Record<string, unknown> = {};
  for (const k of SESSION_KEYS) if (Object.hasOwn(b, k)) out[k] = b[k];
  return out;
}

export async function signIn(raw: string, ip: string | null, deps: SignInDeps): Promise<Outcome> {
  const creds = parseBody(raw);
  if (creds === null) return fail(400, 'VALIDATION_FAILED');

  let gate: GateResult;
  try {
    gate = await deps.begin(creds.login, ip);
  } catch {
    return fail(503, 'INTERNAL');
  }
  if (!gate.allowed) return locked(gate.retry_after_seconds);

  let grant: GrantResult | null = null;
  if (creds.email !== null) {
    try {
      grant = await deps.passwordGrant(creds.email, creds.password);
    } catch {
      return fail(502, 'INTERNAL');
    }
    if (grant.status === 200) {
      const session = pickSession(grant.body);
      if (session === null) return fail(502, 'INTERNAL');
      try {
        await deps.succeeded(creds.login, ip);
      } catch {
        // The person is signed in; a counter left behind expires with its window.
      }
      return { status: 200, body: session };
    }
    if (grant.status === 429) return fail(429, 'RATE_LIMITED', { retry_after_seconds: 60 });
    if (grant.status !== 400) return fail(502, 'INTERNAL');
  }

  // A wrong password, an unknown or banned user, or a value that is not a login at all.
  let result: FailResult;
  try {
    result = await deps.failed(creds.login, ip);
  } catch {
    return fail(503, 'INTERNAL');
  }
  return result.locked ? locked(result.retry_after_seconds) : fail(401, 'WRONG');
}

/**
 * The caller's IP as the platform reports it, or null. Best effort: used only for the per-IP limit
 * (30 attempts per 15 minutes); the per-login lock does not depend on it.
 */
export function clientIp(headers: Headers): string | null {
  const candidates = [
    headers.get('cf-connecting-ip'),
    headers.get('x-real-ip'),
    headers.get('x-forwarded-for')?.split(',')[0] ?? null,
  ];
  for (const c of candidates) {
    const v = c?.trim() ?? '';
    if (v.length > 0 && v.length <= 64 && /^[0-9a-fA-F:.]+$/.test(v)) return v;
  }
  return null;
}
