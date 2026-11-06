// send-alerts: delivers Web Push notifications for every push alert kind (machine_down, washer_idle;
// task and route kinds next). Owner 2026-11-04/05/06; push approved.
// Called only by pg_cron (app.dispatch_send_alerts via pg_net) with `Authorization: Bearer <secret>`;
// the gateway does not verify a JWT for this function (config.toml verify_jwt = false), so the
// shared secret IS the authorization, compared in constant time before anything else happens.
//
// Flow: claim_push_notifications() (atomic, at most once; every push kind) → one push per subscription → revoke 404/410
// subscriptions → mark_push_alert_delivered() for EVERY claimed alert, failures included.
// Responses land in net._http_response, so bodies hold counts only. Never logs secrets, keys,
// endpoints or request bodies; the request body is not read at all.
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { bearerMatches, run, type ClaimedRow, type Deps } from './alerts.ts';
import { createSender, importVapidKeys, validSubject } from './push.ts';

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

const error = (status: number, code: string, message: string) => json(status, { code, message });

let cachedKeys: { pub: string; priv: string; keys: CryptoKeyPair } | null = null;

async function vapidKeys(pub: string, priv: string): Promise<CryptoKeyPair> {
  if (cachedKeys && cachedKeys.pub === pub && cachedKeys.priv === priv) return cachedKeys.keys;
  const keys = await importVapidKeys(pub, priv);
  cachedKeys = { pub, priv, keys };
  return keys;
}

function realDeps(service: SupabaseClient, send: Deps['send']): Deps {
  return {
    async claim() {
      const { data, error } = await service.rpc('claim_push_notifications');
      if (error) throw new Error('claim_failed');
      return (data ?? []) as ClaimedRow[];
    },
    send,
    async revoke(subscriptionId) {
      const { error } = await service
        .from('push_subscriptions')
        .update({ revoked_at: new Date().toISOString() })
        .eq('id', subscriptionId)
        .is('revoked_at', null);
      if (error) throw new Error('revoke_failed');
    },
    async mark(alertId, recipients) {
      const { data, error } = await service.rpc('mark_push_alert_delivered', {
        p_alert_id: alertId,
        p_recipients: recipients,
      });
      if (error) throw new Error('mark_failed');
      return data === true;
    },
  };
}

Deno.serve(async (req) => {
  // 1. Authorize first: nothing else runs without the shared secret.
  const secret = Deno.env.get('SEND_ALERTS_SECRET') ?? '';
  if (!secret) {
    console.error('send-alerts: SEND_ALERTS_SECRET is not set');
    return error(500, 'INTERNAL', 'Not configured.');
  }
  if (!(await bearerMatches(req.headers.get('Authorization'), secret))) {
    return error(401, 'NOT_AUTHORIZED', 'Not authorized.');
  }
  if (req.method !== 'POST') return error(405, 'VALIDATION_FAILED', 'POST only.');

  // 2. Configuration.
  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const vapidPublic = Deno.env.get('VAPID_PUBLIC_KEY');
  const vapidPrivate = Deno.env.get('VAPID_PRIVATE_KEY');
  const subject = Deno.env.get('VAPID_SUBJECT') ?? '';
  if (!url || !serviceKey || !vapidPublic || !vapidPrivate || !validSubject(subject)) {
    // Fail before claiming, so pending alerts stay pending until the config is fixed.
    console.error('send-alerts: missing or invalid env (SUPABASE_*, VAPID_*)');
    return error(500, 'INTERNAL', 'Not configured.');
  }
  let keys: CryptoKeyPair;
  try {
    keys = await vapidKeys(vapidPublic, vapidPrivate);
  } catch {
    console.error('send-alerts: VAPID keys could not be imported');
    return error(500, 'INTERNAL', 'Not configured.');
  }

  // 3. Claim, send, mark.
  const service = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  try {
    const counts = await run(realDeps(service, createSender(keys, subject)));
    if (counts.unmarked > 0) console.error(`send-alerts: ${counts.unmarked} alert(s) not marked`);
    return json(200, counts);
  } catch {
    console.error('send-alerts: claim failed');
    return error(500, 'INTERNAL', 'Claim failed.');
  }
});
