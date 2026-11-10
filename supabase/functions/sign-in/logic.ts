// Pure decision logic for the sign-in Edge Function (owner-approved 2026-11-06: 6-digit passwords with a
// lockout; 2026-11-07: pepper, escalating locks, trusted-IP header). No env, no network: index.ts passes
// the real lockout RPCs, GoTrue and the pepper, logic_test.ts passes fakes.
//
// Flow for {username, password}:
//   1. body: JSON object ≤ 2 KB with exactly `username` (what the person typed: a username, or an
//      email for the owner's own account) and `password` (1–72 bytes). Else 400 VALIDATION_FAILED.
//   2. login = toLoginEmail(username) (same rule as the app); a value that is neither a username nor a
//      strict ASCII email is still counted under its trimmed, lowercased form, and is "wrong" without
//      asking GoTrue.
//   3. _shared/passwordCheck.ts: the lockout (sign_in_begin / sign_in_failed / sign_in_succeeded), then
//      GoTrue's password grant with the PEPPERED password (_shared/pepper.ts); for an account whose stored
//      password predates the pepper, one grant with the typed value inside the same attempt.
//   4. 200 → the session (access_token, refresh_token, expires_in, expires_at, token_type, user) for
//      supabase.auth.setSession. When the typed (pre-pepper) password matched, the stored password is
//      re-stored peppered (upgrade: app_metadata.pw_v = 2; must_change_password when the typed value
//      breaks today's password rules). An upgrade failure never blocks the sign-in (it retries next time).
//   5. Wrong → 401 WRONG; locked → 429 LOCKED {retry_after_seconds}; GoTrue 429 → 429 RATE_LIMITED;
//      lockout store down → 503 INTERNAL (fail closed); GoTrue broken → 502 INTERNAL. Unknown logins get
//      the same answers as real ones.
//
// Shared plant iPad (owner 2026-11-10): {device_token} → 200 {people: [{id, name}]} (empty for an unknown
// or revoked device); {device_token, member_id, password} → the login of that listed person is looked up
// (service role, live device only, never an owner) and then steps 3–5 run exactly as above.
//
// Nothing here logs; index.ts logs only status codes (never usernames, passwords, tokens or bodies).
import { toLoginEmail } from '../_shared/loginId.ts';
import { checkPassword, type PasswordCheckDeps } from '../_shared/passwordCheck.ts';
import { passwordProblem } from '../_shared/passwordRules.ts';
import type { GrantResult } from '../_shared/passwordCheck.ts';

export type {
  FailResult,
  GateResult,
  GrantResult,
  PasswordCheckDeps,
} from '../_shared/passwordCheck.ts';

export const MAX_BODY_BYTES = 2048;
export const MAX_PASSWORD_BYTES = 72;
const MAX_LOGIN_CHARS = 254;

export interface SignInDeps extends PasswordCheckDeps {
  /** Re-store a pre-pepper password peppered (admin update by user id). Throws on failure. */
  upgradePassword(userId: string, peppered: string, mustChange: boolean): Promise<void>;
  /** Shared plant iPad: the people a live device lists (none for an unknown or revoked device). Throws on a store error. */
  devicePeople(token: string): Promise<DevicePerson[]>;
  /** Shared plant iPad: the login of a person the live device lists right now, else null. Throws on a store error. */
  deviceLogin(token: string, memberId: string): Promise<string | null>;
}

export interface DevicePerson {
  member_id: string;
  display_name: string;
}

export type Code = 'VALIDATION_FAILED' | 'LOCKED' | 'WRONG' | 'RATE_LIMITED' | 'INTERNAL';
export interface Outcome {
  status: number;
  body: Record<string, unknown>;
  /** Set when a pre-pepper password was re-stored (true) or the upgrade failed (false); for logs. */
  upgraded?: boolean;
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

/** The raw body as a plain JSON object with exactly `keys`, else null. */
function jsonObject(raw: string, keys: readonly string[]): Record<string, unknown> | null {
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) return null;
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    return null;
  }
  if (body === null || typeof body !== 'object' || Array.isArray(body)) return null;
  const have = Object.keys(body);
  if (have.length !== keys.length || !keys.every((k) => have.includes(k))) return null;
  return body as Record<string, unknown>;
}

function validPassword(password: unknown): password is string {
  if (typeof password !== 'string') return false;
  const pwBytes = new TextEncoder().encode(password).length;
  return pwBytes > 0 && pwBytes <= MAX_PASSWORD_BYTES;
}

/** Parses the raw body. Values are never echoed in errors. */
export function parseBody(raw: string): Credentials | null {
  const body = jsonObject(raw, ['username', 'password']);
  if (body === null) return null;
  const { username, password } = body;
  if (typeof username !== 'string' || !validPassword(password)) return null;
  const typed = username.trim().toLowerCase();
  if (typed.length === 0 || typed.length > MAX_LOGIN_CHARS) return null;
  const email = toLoginEmail(username);
  return { login: email ?? typed, email, password };
}

const DEVICE_TOKEN = /^[0-9a-f]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * Shared plant iPad (owner 2026-11-10) bodies:
 *   {device_token}                         → the names this device lists;
 *   {device_token, member_id, password}    → sign in as that listed person.
 */
export type DeviceRequest =
  | { kind: 'people'; token: string }
  | { kind: 'sign_in'; token: string; memberId: string; password: string };

export function parseDeviceBody(raw: string): DeviceRequest | null {
  const list = jsonObject(raw, ['device_token']);
  if (list !== null) {
    return typeof list.device_token === 'string' && DEVICE_TOKEN.test(list.device_token)
      ? { kind: 'people', token: list.device_token }
      : null;
  }
  const b = jsonObject(raw, ['device_token', 'member_id', 'password']);
  if (b === null) return null;
  const { device_token: token, member_id: memberId, password } = b;
  if (typeof token !== 'string' || !DEVICE_TOKEN.test(token)) return null;
  if (typeof memberId !== 'string' || !UUID.test(memberId.toLowerCase())) return null;
  if (!validPassword(password)) return null;
  return { kind: 'sign_in', token, memberId: memberId.toLowerCase(), password };
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

function userId(session: Record<string, unknown>): string | null {
  const user = session.user as { id?: unknown } | undefined;
  return typeof user?.id === 'string' && user.id.length > 0 ? user.id : null;
}

export async function signIn(raw: string, ip: string | null, deps: SignInDeps): Promise<Outcome> {
  const creds = parseBody(raw);
  if (creds !== null) return await passwordSignIn(creds, ip, deps);
  const device = parseDeviceBody(raw);
  if (device === null) return fail(400, 'VALIDATION_FAILED');

  if (device.kind === 'people') {
    // Unknown and revoked devices get the same empty list as a device with nobody on it.
    let people: DevicePerson[];
    try {
      people = await deps.devicePeople(device.token);
    } catch {
      return fail(503, 'INTERNAL');
    }
    return {
      status: 200,
      body: { people: people.map((p) => ({ id: p.member_id, name: p.display_name })) },
    };
  }

  let login: string | null;
  try {
    login = await deps.deviceLogin(device.token, device.memberId);
  } catch {
    return fail(503, 'INTERNAL');
  }
  // Not a listed person on a live device: the same answer as a wrong password (nothing to count; the
  // caller has no login to guess at).
  if (login === null) return fail(401, 'WRONG');
  // From here on it is exactly the normal sign-in for that login: same lockout key, same pepper.
  return await passwordSignIn({ login, email: login, password: device.password }, ip, deps);
}

async function passwordSignIn(
  creds: Credentials,
  ip: string | null,
  deps: SignInDeps,
): Promise<Outcome> {
  const result = await checkPassword(deps, creds.login, creds.email, creds.password, ip);
  switch (result.kind) {
    case 'locked':
      return locked(result.retryAfterSeconds);
    case 'wrong':
      return fail(401, 'WRONG');
    case 'rate_limited':
      return fail(429, 'RATE_LIMITED', { retry_after_seconds: 60 });
    case 'error':
      return fail(result.status, 'INTERNAL');
  }

  const session = pickSession(result.grant.body);
  if (session === null) return fail(502, 'INTERNAL');
  const outcome: Outcome = { status: 200, body: session };
  if (result.legacy && creds.email !== null) {
    // One-time upgrade of a pre-pepper password. Never blocks the sign-in.
    const id = userId(session);
    const peppered = await deps.pepper(creds.email, creds.password);
    try {
      if (id === null) throw new Error('no user id');
      await deps.upgradePassword(id, peppered, passwordProblem(creds.password) !== null);
    } catch {
      // Not re-stored: the legacy session is still valid; the upgrade is tried again next time.
      outcome.upgraded = false;
      return outcome;
    }
    outcome.upgraded = true;
    // E2E bug B1 (2026-11-07): GoTrue ends the user's sessions when the admin API changes the
    // password, so the session from the legacy grant is already dead. Sign in again with the new
    // peppered password and hand THAT session to the app. Same reserved attempt; no extra count.
    // If this fails, the password IS upgraded already: a retry works through the normal peppered path.
    let fresh: GrantResult;
    try {
      fresh = await deps.passwordGrant(creds.email, peppered);
    } catch {
      return { ...fail(502, 'INTERNAL'), upgraded: true };
    }
    if (fresh.status === 429) {
      return { ...fail(429, 'RATE_LIMITED', { retry_after_seconds: 60 }), upgraded: true };
    }
    const freshSession = fresh.status === 200 ? pickSession(fresh.body) : null;
    if (freshSession === null) return { ...fail(502, 'INTERNAL'), upgraded: true };
    outcome.body = freshSession;
  }
  return outcome;
}

/** The IP address characters we accept from a trusted header (IPv4 / IPv6, ≤ 64 chars). */
function validIp(v: string | null | undefined): string | null {
  const s = v?.trim() ?? '';
  return s.length > 0 && s.length <= 64 && /^[0-9a-fA-F:.]+$/.test(s) ? s : null;
}

/**
 * The caller's IP for the per-IP limit, ONLY from the header the platform is known to set (security
 * review M2: the leftmost X-Forwarded-For, and any header the caller can send, is attacker-controlled).
 *
 * `trusted` comes from the function secret SIGN_IN_TRUSTED_IP_HEADER:
 *   * unset / empty (the default) → null: no per-IP limit; the per-login lock (with escalation) and the
 *     pepper carry the protection. Chosen because a wrong guess here is worse than no IP limit: trusting
 *     a spoofable header lets an attacker rotate fake IPs (no limit anyway) or send the plant's NAT IP and
 *     lock every phone in the building out.
 *   * a header name, e.g. `cf-connecting-ip` or `x-real-ip` → that header's value.
 *   * `x-forwarded-for:N` → the N-th entry from the RIGHT (1 = the last one, the address the nearest
 *     trusted proxy appended). Plain `x-forwarded-for` means `x-forwarded-for:1`.
 * Set it only after the diagnostic (headerDiagnostic) showed which header the platform sets.
 */
export function clientIp(headers: Headers, trusted: string | null | undefined): string | null {
  const spec = (trusted ?? '').trim().toLowerCase();
  if (spec === '') return null;
  const m = /^x-forwarded-for(?::([1-9]))?$/.exec(spec);
  if (m) {
    const parts = (headers.get('x-forwarded-for') ?? '').split(',').map((p) => p.trim());
    const n = Number(m[1] ?? '1');
    return parts.length >= n ? validIp(parts[parts.length - n]) : null;
  }
  if (!/^[a-z0-9-]{1,64}$/.test(spec)) return null;
  return validIp(headers.get(spec));
}

const DIAGNOSTIC_CANDIDATES = [
  'cf-connecting-ip',
  'cf-connecting-ipv6',
  'true-client-ip',
  'x-real-ip',
  'x-forwarded-for',
  'forwarded',
  'x-client-ip',
  'x-cluster-client-ip',
  'x-envoy-external-address',
  'fly-client-ip',
];

/**
 * SIGN_IN_HEADER_DIAGNOSTIC=on (one-time check after deploy): which IP-carrying headers the platform
 * passes, by NAME only (plus how many X-Forwarded-For entries), never a value. Also any other header
 * whose name mentions "ip" or "forward". index.ts logs it once per function instance.
 */
export function headerDiagnostic(headers: Headers): string[] {
  const out: string[] = [];
  const names = new Set<string>();
  headers.forEach((_v, k) => names.add(k.toLowerCase()));
  for (const c of DIAGNOSTIC_CANDIDATES) {
    if (!names.has(c)) continue;
    out.push(
      c === 'x-forwarded-for'
        ? `x-forwarded-for(entries=${(headers.get(c) ?? '').split(',').length})`
        : c,
    );
  }
  for (const n of [...names].sort()) {
    if (!DIAGNOSTIC_CANDIDATES.includes(n) && /(^|-)(ip|ipv6)($|-)|forward/.test(n)) out.push(n);
  }
  return out;
}
