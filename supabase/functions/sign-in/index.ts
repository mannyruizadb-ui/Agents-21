// sign-in: the app's username + password sign-in, with a lockout (owner-approved 2026-11-06).
//
// Public (verify_jwt = false: the caller is not signed in yet), browser-called from the site's own
// origins only (CORS allow-list, as manage-users). One POST: {username, password}. The decision logic is
// in logic.ts; this file wires in:
//   * the lockout RPCs (sign_in_begin / sign_in_failed / sign_in_succeeded) with the SERVICE ROLE
//     (they are granted to nobody else), and
//   * GoTrue's password grant, called server-side with the publishable (anon) key.
// The response carries the session for supabase.auth.setSession, or {code, message[, retry_after_seconds]}.
//
// Limits: a login is locked for 15 minutes after 5 wrong passwords in 15 minutes; an IP after 30
// attempts in 15 minutes. GoTrue's own /token endpoint stays reachable directly with the publishable
// key (Supabase Pro has no password-verification hook), where only Supabase's per-IP rate limits apply.
//
// Never logs usernames, passwords, tokens, IPs or bodies: only status codes.
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { corsHeaders, parseAllowedOrigins } from '../_shared/cors.ts';
import {
  clientIp,
  type FailResult,
  type GateResult,
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

function deps(): SignInDeps {
  const url = env('SUPABASE_URL');
  const anonKey = env('SUPABASE_ANON_KEY');
  const service: SupabaseClient = createClient(url, env('SUPABASE_SERVICE_ROLE_KEY'), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await service.rpc(fn, args);
    if (error) {
      console.error('sign-in: lockout store error', fn, error.code);
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
    outcome = await signIn(new TextDecoder().decode(bytes), clientIp(req.headers), deps());
  } catch (e) {
    console.error('sign-in: unexpected error', e instanceof Error ? e.name : 'unknown');
    outcome = { status: 500, body: { code: 'INTERNAL', message: 'Could not sign in right now.' } };
  }
  if (outcome.status !== 200) console.log('sign-in:', outcome.status, outcome.body.code);
  return json(outcome.status, outcome.body, cors);
});
