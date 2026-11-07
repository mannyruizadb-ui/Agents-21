// The one password check (2026-11-07): used by sign-in (signing in) and manage-users
// (change_own_password verifies the current password). Every check goes through the sign-in lockout and
// sends GoTrue only the PEPPERED password (pepper.ts), so neither function can be used to guess around the
// lockout, and a guess sent straight to GoTrue is a guess at a 256-bit value.
//
//   1. lockout.begin(login, ip): refused while the login or the IP is locked (nothing else happens).
//   2. GoTrue password grant with pepper(login, typed). 200 → lockout.succeeded → ok.
//   3. 400 and the account's stored password predates the pepper (legacyPassword(login), i.e.
//      app_metadata.pw_v is not 2) and legacy upgrade is on → ONE grant with the typed value, inside the
//      same reserved attempt. 200 → ok with legacy = true (the caller re-stores the password peppered).
//   4. Otherwise lockout.failed(login, ip) → wrong, or locked when this failure locked the login.
//   Any lockout-store error → error 503: GoTrue is never called without the lockout check (fail closed).
//   GoTrue 429 → rate_limited (not counted); any other GoTrue status → error 502 (not counted).
//
// Pure: no env, no network (callers pass the real RPCs and fetch; tests pass fakes). Never logs.

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

export interface PasswordCheckDeps {
  begin(login: string, ip: string | null): Promise<GateResult>;
  failed(login: string, ip: string | null): Promise<FailResult>;
  succeeded(login: string, ip: string | null): Promise<void>;
  /** POST /auth/v1/token?grant_type=password. Throws on a network error. */
  passwordGrant(email: string, password: string): Promise<GrantResult>;
  /** pepper.ts pepperPassword with the configured pepper. */
  pepper(login: string, typed: string): Promise<string>;
  /** sign_in_account_state: the login is an account whose stored password predates the pepper. */
  legacyPassword(login: string): Promise<boolean>;
  /** One-time upgrade of pre-pepper passwords (SIGN_IN_LEGACY_UPGRADE, default on). */
  legacyUpgrade: boolean;
}

export type CheckResult =
  | { kind: 'ok'; grant: GrantResult; legacy: boolean }
  | { kind: 'locked'; retryAfterSeconds: number }
  | { kind: 'wrong' }
  | { kind: 'rate_limited' }
  | { kind: 'error'; status: 502 | 503 };

/**
 * Checks `typed` for `login` (the normalised login; the lockout key). `email` is the auth email to send
 * to GoTrue, or null when the typed login is not a valid username or email (then it is only counted).
 */
export async function checkPassword(
  deps: PasswordCheckDeps,
  login: string,
  email: string | null,
  typed: string,
  ip: string | null,
): Promise<CheckResult> {
  let gate: GateResult;
  try {
    gate = await deps.begin(login, ip);
  } catch {
    return { kind: 'error', status: 503 };
  }
  if (!gate.allowed) return { kind: 'locked', retryAfterSeconds: gate.retry_after_seconds };

  if (email !== null) {
    let grant: GrantResult;
    try {
      grant = await deps.passwordGrant(email, await deps.pepper(email, typed));
    } catch {
      return { kind: 'error', status: 502 };
    }
    if (grant.status === 200) return await ok(deps, login, ip, grant, false);
    if (grant.status === 429) return { kind: 'rate_limited' };
    if (grant.status !== 400) return { kind: 'error', status: 502 };

    if (deps.legacyUpgrade) {
      let legacy: boolean;
      try {
        legacy = await deps.legacyPassword(email);
      } catch {
        return { kind: 'error', status: 503 };
      }
      if (legacy) {
        try {
          grant = await deps.passwordGrant(email, typed);
        } catch {
          return { kind: 'error', status: 502 };
        }
        if (grant.status === 200) return await ok(deps, login, ip, grant, true);
        if (grant.status === 429) return { kind: 'rate_limited' };
        if (grant.status !== 400) return { kind: 'error', status: 502 };
      }
    }
  }

  // A wrong password, an unknown or banned user, or a value that is not a login at all.
  let result: FailResult;
  try {
    result = await deps.failed(login, ip);
  } catch {
    return { kind: 'error', status: 503 };
  }
  return result.locked
    ? { kind: 'locked', retryAfterSeconds: result.retry_after_seconds }
    : { kind: 'wrong' };
}

async function ok(
  deps: PasswordCheckDeps,
  login: string,
  ip: string | null,
  grant: GrantResult,
  legacy: boolean,
): Promise<CheckResult> {
  try {
    await deps.succeeded(login, ip);
  } catch {
    // The password was right; a counter left behind expires with its window.
  }
  return { kind: 'ok', grant, legacy };
}
