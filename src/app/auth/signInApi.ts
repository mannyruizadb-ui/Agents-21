import { FunctionsHttpError } from '@supabase/supabase-js';
import { supabase } from '../../lib/supabase';

// Client for the `sign-in` Edge Function (2026-11-07: lockout + password pepper). The function checks
// the password through the lockout and returns the session; the app then calls setSession. Contract
// (supabase/functions/sign-in/logic.ts): 200 → session; 401 WRONG; 429 LOCKED {retry_after_seconds};
// 429 RATE_LIMITED; 400 VALIDATION_FAILED; 5xx INTERNAL.

export type SignInResult =
  | { kind: 'ok'; accessToken: string; refreshToken: string }
  | { kind: 'wrong' }
  | { kind: 'locked'; minutes: number }
  | { kind: 'rate_limited' }
  | { kind: 'failed' };

/** Whole minutes to wait, rounded up (at least 1). */
export function retryMinutes(seconds: unknown): number {
  const s = typeof seconds === 'number' && Number.isFinite(seconds) ? seconds : 60;
  return Math.max(1, Math.ceil(s / 60));
}

/** Pure: what a sign-in response means for the screen. */
export function classifySignInResponse(status: number, body: unknown): SignInResult {
  const b = (body !== null && typeof body === 'object' ? body : {}) as Record<string, unknown>;
  if (status === 200) {
    if (typeof b.access_token === 'string' && typeof b.refresh_token === 'string') {
      return { kind: 'ok', accessToken: b.access_token, refreshToken: b.refresh_token };
    }
    return { kind: 'failed' };
  }
  if (status === 429 && b.code === 'LOCKED') {
    return { kind: 'locked', minutes: retryMinutes(b.retry_after_seconds) };
  }
  if (status === 429) return { kind: 'rate_limited' };
  // 401 WRONG, and 400 VALIDATION_FAILED (an empty or impossible value): same message as a wrong
  // password, never says whether the user exists.
  if (status === 401 || status === 400) return { kind: 'wrong' };
  return { kind: 'failed' };
}

export async function callSignIn(username: string, password: string): Promise<SignInResult> {
  try {
    const { data, error } = await supabase.functions.invoke<unknown>('sign-in', {
      body: { username, password },
    });
    if (!error) return classifySignInResponse(200, data);
    if (error instanceof FunctionsHttpError) {
      const res = error.context as Response;
      const body: unknown = await res.json().catch(() => null);
      return classifySignInResponse(res.status, body);
    }
    return { kind: 'failed' };
  } catch {
    return { kind: 'failed' };
  }
}
