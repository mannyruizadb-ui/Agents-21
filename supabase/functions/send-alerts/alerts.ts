// Pure logic for send-alerts (no env, no network): auth compare, endpoint allow-list, message text,
// grouping of claimed rows and the claim → send → mark loop. index.ts wires in the real client and
// the Web Push sender; the tests pass mocks.

/** One row of public.claim_push_alerts(): an alert × one active subscription of a recipient. */
export interface ClaimedRow {
  alert_id: string;
  machine_id: string;
  machine_name: string;
  reason_code: string | null;
  down_since: string;
  still_down: boolean;
  subscription_id: string;
  language: string | null;
  endpoint: string;
  p256dh: string;
  auth: string;
}

/** What public/sw.js reads. Never free text: the lock screen shows it. */
export interface PushPayload {
  title: string;
  body: string;
  tag: string;
  url: string;
}

export interface PushTarget {
  endpoint: string;
  p256dh: string;
  auth: string;
}

/** ok, gone (404/410: the browser unsubscribed) or failed (anything else, timeouts included). */
export type SendResult = 'ok' | 'gone' | 'failed';

export interface Deps {
  claim(): Promise<ClaimedRow[]>;
  send(target: PushTarget, payload: PushPayload): Promise<SendResult>;
  revoke(subscriptionId: string): Promise<void>;
  mark(alertId: string, recipients: string[]): Promise<boolean>;
}

export interface RunCounts {
  alerts: number;
  sent: number;
  failed: number;
  revoked: number;
  stale: number;
  skipped: number;
  unmarked: number;
}

export const PLANT_TIME_ZONE = 'America/New_York';
export const ALERT_URL = '/control/washers';
const MAX_NAME_CHARS = 60;
const SEND_CONCURRENCY = 8;

// ---------------------------------------------------------------------------------------------
// Auth

/**
 * Constant-time check of an `Authorization: Bearer <secret>` header. Both sides are hashed first,
 * so neither the content nor the length of the secret leaks through timing. An empty or missing
 * secret never matches.
 */
export async function bearerMatches(header: string | null, secret: string): Promise<boolean> {
  if (!secret || header === null || !header.startsWith('Bearer ')) return false;
  const given = header.slice('Bearer '.length);
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest('SHA-256', enc.encode(given)),
    crypto.subtle.digest('SHA-256', enc.encode(secret)),
  ]);
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

// ---------------------------------------------------------------------------------------------
// Endpoint allow-list (mirrors app.is_allowed_push_endpoint, migration 20261104202925)

const ALLOWED_EXACT = new Set(['fcm.googleapis.com', 'updates.push.services.mozilla.com']);
const ALLOWED_SUFFIXES = ['.push.apple.com', '.notify.windows.com'];
const LABEL = /^[a-z0-9-]+$/;

/** True for an https URL with no port or userinfo on an allow-listed Web Push host. */
export function isAllowedPushEndpoint(endpoint: string): boolean {
  let url: URL;
  try {
    url = new URL(endpoint);
  } catch {
    return false;
  }
  if (url.protocol !== 'https:' || url.port !== '' || url.username !== '' || url.password !== '') {
    return false;
  }
  const host = url.hostname.toLowerCase();
  if (ALLOWED_EXACT.has(host)) return true;
  return ALLOWED_SUFFIXES.some((suffix) => {
    if (!host.endsWith(suffix)) return false;
    const prefix = host.slice(0, -suffix.length);
    return prefix.length > 0 && prefix.split('.').every((l) => LABEL.test(l));
  });
}

// ---------------------------------------------------------------------------------------------
// Message text (preset reason codes only; matches src/locales machines.reasons.*)

type Lang = 'en' | 'es';

const REASONS: Record<Lang, Record<string, string>> = {
  en: {
    water_pump: 'Water pump',
    soap_dispenser: 'Soap dispenser',
    wont_start: "Won't start",
    leaking: 'Leaking',
    other: 'Other (see the app)',
  },
  es: {
    water_pump: 'Bomba de agua',
    soap_dispenser: 'Dosificador de jabón',
    wont_start: 'No arranca',
    leaking: 'Gotea',
    other: 'Otro (ver la app)',
  },
};

export function pickLanguage(language: string | null): Lang {
  return language?.toLowerCase().split(/[-_]/)[0] === 'es' ? 'es' : 'en';
}

/** Translated preset reason, or null for an unknown code (never echo the code or free text). */
export function reasonLabel(code: string | null, lang: Lang): string | null {
  if (code === null) return null;
  return Object.hasOwn(REASONS[lang], code) ? REASONS[lang][code] : null;
}

function cleanName(name: string): string {
  // Strip control characters and cap the length; machine names are setup data.
  // deno-lint-ignore no-control-regex
  // eslint-disable-next-line no-control-regex -- stripping control characters is the point here
  const flat = name.replace(/[\u0000-\u001f\u007f]+/g, ' ').trim();
  return flat.length > MAX_NAME_CHARS ? `${flat.slice(0, MAX_NAME_CHARS - 1)}…` : flat;
}

/** "9:42 PM" / "9:42 p. m." in the plant's time zone; null when the timestamp is unreadable. */
export function formatTime(iso: string, lang: Lang, timeZone = PLANT_TIME_ZONE): string | null {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return new Intl.DateTimeFormat(lang === 'es' ? 'es-US' : 'en-US', {
    hour: 'numeric',
    minute: '2-digit',
    timeZone,
  }).format(d);
}

function hourIsOne(iso: string, timeZone: string): boolean {
  const h = new Intl.DateTimeFormat('en-US', { hour: 'numeric', hour12: true, timeZone })
    .formatToParts(new Date(iso))
    .find((p) => p.type === 'hour')?.value;
  return h === '1';
}

export function buildPayload(
  row: Pick<ClaimedRow, 'machine_id' | 'machine_name' | 'reason_code' | 'down_since' | 'language'>,
  timeZone = PLANT_TIME_ZONE,
): PushPayload {
  const lang = pickLanguage(row.language);
  const name = cleanName(row.machine_name) || (lang === 'es' ? 'Una máquina' : 'A machine');
  const title = lang === 'es' ? `${name} está fuera de servicio` : `${name} is down`;
  const reason = reasonLabel(row.reason_code, lang);
  const time = formatTime(row.down_since, lang, timeZone);
  let since: string | null = null;
  if (time !== null) {
    since =
      lang === 'es'
        ? `desde ${hourIsOne(row.down_since, timeZone) ? 'la' : 'las'} ${time}`
        : `since ${time}`;
  }
  const parts = [reason, since].filter((p): p is string => p !== null);
  let body = parts.join(' · ');
  if (body && reason === null) body = body.charAt(0).toUpperCase() + body.slice(1);
  return { title, body, tag: `machine-${row.machine_id}`, url: ALERT_URL };
}

// ---------------------------------------------------------------------------------------------
// Claim → send → mark

export interface AlertGroup {
  alertId: string;
  stillDown: boolean;
  /** One row per subscription (duplicates of the same subscription dropped). */
  rows: ClaimedRow[];
}

export function groupByAlert(rows: ClaimedRow[]): AlertGroup[] {
  const groups = new Map<string, AlertGroup>();
  for (const row of rows) {
    let g = groups.get(row.alert_id);
    if (!g) {
      g = { alertId: row.alert_id, stillDown: true, rows: [] };
      groups.set(row.alert_id, g);
    }
    if (row.still_down !== true) g.stillDown = false;
    if (!g.rows.some((r) => r.subscription_id === row.subscription_id)) g.rows.push(row);
  }
  return [...groups.values()];
}

async function pool<T>(items: T[], limit: number, fn: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const item = items[next++];
      await fn(item);
    }
  });
  await Promise.all(workers);
}

/**
 * Claims the pending alerts, sends one push per subscription, revokes gone subscriptions, and
 * marks EVERY claimed alert: the subscription ids that got the push, or 'stale' (machine already
 * back up), 'failed' (every send failed) or 'none' (no allowed endpoint).
 */
export async function run(deps: Deps): Promise<RunCounts> {
  const counts: RunCounts = {
    alerts: 0,
    sent: 0,
    failed: 0,
    revoked: 0,
    stale: 0,
    skipped: 0,
    unmarked: 0,
  };
  const groups = groupByAlert(await deps.claim());
  counts.alerts = groups.length;

  for (const group of groups) {
    let recipients: string[];
    try {
      if (!group.stillDown) {
        counts.stale++;
        recipients = ['stale'];
      } else {
        const sentIds: string[] = [];
        let attempted = 0;
        await pool(group.rows, SEND_CONCURRENCY, async (row) => {
          if (!isAllowedPushEndpoint(row.endpoint)) {
            counts.skipped++;
            return;
          }
          attempted++;
          let result: SendResult;
          try {
            result = await deps.send(
              { endpoint: row.endpoint, p256dh: row.p256dh, auth: row.auth },
              buildPayload(row),
            );
          } catch {
            result = 'failed';
          }
          if (result === 'ok') {
            sentIds.push(row.subscription_id);
            counts.sent++;
            return;
          }
          counts.failed++;
          if (result === 'gone') {
            try {
              await deps.revoke(row.subscription_id);
              counts.revoked++;
            } catch {
              // the next run's push gets 410 again and retries the revoke
            }
          }
        });
        recipients = sentIds.length > 0 ? sentIds : attempted > 0 ? ['failed'] : ['none'];
      }
    } catch {
      recipients = ['failed'];
    }
    try {
      if (!(await deps.mark(group.alertId, recipients))) counts.unmarked++;
    } catch {
      counts.unmarked++;
    }
  }
  return counts;
}
