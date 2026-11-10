// sign-in: the app's username + password sign-in, with a lockout (owner-approved 2026-11-06) and a
// password pepper (owner-approved 2026-11-07, security review H1).
//
// Public (verify_jwt = false: the caller is not signed in yet), browser-called from the site's own
// origins only (CORS allow-list, as manage-users). One POST: {username, password}; or, from the shared
// plant iPad (2026-11-10), {device_token} for the list of names and {device_token, member_id, password}
// to sign in as one of them (logic.ts parseDeviceBody). The decision logic is
// in logic.ts and ../_shared/passwordCheck.ts; this file wires in:
//   * the lockout RPCs (sign_in_begin / sign_in_failed / sign_in_succeeded) and sign_in_account_state
//     with the SERVICE ROLE (they are granted to nobody else),
//   * GoTrue's password grant, called server-side with the publishable (anon) key and the PEPPERED
//     password (../_shared/pepper.ts), and the admin update that re-stores a pre-pepper password.
// The response carries the session for supabase.auth.setSession, or {code, message[, retry_after_seconds]}.
//
// Function secrets / env (names only; values never logged):
//   SIGN_IN_PEPPER             required (≥ 32 chars). Missing → every request 503 (fail closed). Shared with
//                              manage-users. Rotating it = every account needs a password reset.
//   SIGN_IN_TRUSTED_IP_HEADER  optional; the header the platform sets with the caller's IP (logic.ts
//                              clientIp). Unset (default) → no per-IP limit; the per-login lock applies.
//   SIGN_IN_HEADER_DIAGNOSTIC  'on' → log once per instance WHICH IP headers arrive (names, never values).
//   SIGN_IN_LEGACY_UPGRADE     'off' disables the one-time upgrade of pre-pepper passwords (default on).
//   ALLOWED_ORIGINS, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.
//
// Limits: a login is locked after 5 wrong passwords in 15 minutes, 15 min doubling for each new lock
// within 24 h of the previous (capped at 24 h); an IP (only with a trusted header) after 30 attempts in
// 15 minutes. GoTrue's own /token endpoint stays reachable directly with the publishable key, but it
// only ever sees peppered passwords, so a direct guess is a guess at a 256-bit value.
//
// Never logs usernames, passwords, tokens, IPs, header values or bodies: only status codes.
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { corsHeaders, parseAllowedOrigins } from '../_shared/cors.ts';
import { pepperPassword, PASSWORD_VERSION, requirePepper } from '../_shared/pepper.ts';
import {
  clientIp,
  type DevicePerson,
  type FailResult,
  type GateResult,
  headerDiagnostic,
  MAX_BODY_BYTES,
  type Outcome,
  signIn,
  type SignInDeps,
} from './logic.ts';

const GOTRUE_TIMEOUT_MS = 10_000;

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing env ${name}`);
  return value;
}

function json(status: number, body: unknown, cors: Record<string, string>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

function firstRow<T>(data: unknown): T {
  const row = Array.isArray(data) ? data[0] : data;
  if (row === null || typeof row !== 'object') throw new Error('no row');
  return row as T;
}

let diagnosed = false;

function deps(pepper: string): SignInDeps {
  const url = env('SUPABASE_URL');
  const anonKey = env('SUPABASE_ANON_KEY');
  const service: SupabaseClient = createClient(url, env('SUPABASE_SERVICE_ROLE_KEY'), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await service.rpc(fn, args);
    if (error) {
      console.error('sign-in: store error', fn, error.code);
      throw new Error('lockout store');
    }
    return data;
  };
  return {
    begin: async (login, ip) =>
      firstRow<GateResult>(await rpc('sign_in_begin', { p_login: login, p_ip: ip })),
    failed: async (login, ip) =>
      firstRow<FailResult>(await rpc('sign_in_failed', { p_login: login, p_ip: ip })),
    succeeded: async (login, ip) => {
      await rpc('sign_in_succeeded', { p_login: login, p_ip: ip });
    },
    legacyPassword: async (login) =>
      firstRow<{ legacy_password: boolean }>(await rpc('sign_in_account_state', { p_login: login }))
        .legacy_password === true,
    legacyUpgrade: Deno.env.get('SIGN_IN_LEGACY_UPGRADE') !== 'off',
    pepper: (login, typed) => pepperPassword(pepper, login, typed),
    upgradePassword: async (userId, peppered, mustChange) => {
      const { error } = await service.auth.admin.updateUserById(userId, {
        password: peppered,
        app_metadata: {
          pw_v: PASSWORD_VERSION,
          ...(mustChange ? { must_change_password: true } : {}),
        },
      });
      if (error) throw new Error('upgrade');
    },
    // Shared plant iPad (2026-11-10): service-role-only lookups keyed by the device token.
    devicePeople: async (token) => {
      const data = await rpc('shared_device_people', { p_token: token });
      return Array.isArray(data) ? (data as DevicePerson[]) : [];
    },
    deviceLogin: async (token, memberId) => {
      const data = await rpc('shared_device_login', { p_token: token, p_member_id: memberId });
      return typeof data === 'string' && data.length > 0 ? data : null;
    },
    passwordGrant: async (email, password) => {
      const res = await fetch(`${url}/auth/v1/token?grant_type=password`, {
        method: 'POST',
        headers: { apikey: anonKey, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password }),
        signal: AbortSignal.timeout(GOTRUE_TIMEOUT_MS),
      });
      const body = await res.json().catch(() => null);
      if (res.status !== 200 && res.status !== 400) {
        console.error('sign-in: auth status', res.status);
      }
      return { status: res.status, body };
    },
  };
}

Deno.serve(async (req) => {
  const cors = corsHeaders(
    req.headers.get('Origin'),
    parseAllowedOrigins(Deno.env.get('ALLOWED_ORIGINS')),
  );
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') {
    return json(405, { code: 'VALIDATION_FAILED', message: 'Use POST.' }, cors);
  }
  const declared = Number(req.headers.get('Content-Length') ?? '0');
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
    return json(413, { code: 'VALIDATION_FAILED', message: 'Request too large.' }, cors);
  }
  if (!diagnosed && Deno.env.get('SIGN_IN_HEADER_DIAGNOSTIC') === 'on') {
    diagnosed = true;
    console.log(
      'sign-in: ip header diagnostic:',
      headerDiagnostic(req.headers).join(' ') || 'none',
    );
  }
  let pepper: string;
  try {
    pepper = requirePepper(Deno.env.get('SIGN_IN_PEPPER'));
  } catch {
    console.error('sign-in: SIGN_IN_PEPPER is not configured');
    return json(
      503,
      { code: 'INTERNAL', message: 'Could not sign in right now. Try again.' },
      cors,
    );
  }
  let outcome: Outcome;
  try {
    // Read at most MAX_BODY_BYTES + 1 bytes, whatever Content-Length says.
    const reader = req.body?.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (reader) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > MAX_BODY_BYTES) {
        await reader.cancel();
        return json(413, { code: 'VALIDATION_FAILED', message: 'Request too large.' }, cors);
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const c of chunks) {
      bytes.set(c, offset);
      offset += c.length;
    }
    outcome = await signIn(
      new TextDecoder().decode(bytes),
      clientIp(req.headers, Deno.env.get('SIGN_IN_TRUSTED_IP_HEADER')),
      deps(pepper),
    );
  } catch (e) {
    console.error('sign-in: unexpected error', e instanceof Error ? e.name : 'unknown');
    outcome = { status: 500, body: { code: 'INTERNAL', message: 'Could not sign in right now.' } };
  }
  if (outcome.status !== 200) console.log('sign-in:', outcome.status, outcome.body.code);
  if (outcome.upgraded !== undefined)
    console.log('sign-in: password upgrade', outcome.upgraded ? 'done' : 'failed');
  return json(outcome.status, outcome.body, cors);
});
