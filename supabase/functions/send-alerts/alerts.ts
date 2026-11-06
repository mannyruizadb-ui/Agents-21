// Pure logic for send-alerts (no env, no network): auth compare, endpoint allow-list, message text,
// grouping of claimed rows and the claim → send → mark loop. index.ts wires in the real client and
// the Web Push sender; the tests pass mocks.

/**
 * One row of public.claim_push_notifications(): an alert × one active subscription of a recipient.
 * `payload` is app.alert_payload(alert): per kind, never free text (a task's own text will be the
 * only exception, and only to its assignees and owners).
 */
export interface ClaimedRow {
  alert_id: string;
  kind: string;
  payload: Record<string, unknown> | null;
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
  /** subscriptions skipped because their endpoint is not on the allow-list */
  skipped: number;
  /** alerts of a kind this function cannot send yet, or with an unusable payload (marked 'none') */
  unsupported: number;
  unmarked: number;
}

export const PLANT_TIME_ZONE = 'America/New_York';
export const ALERT_URL = '/control/washers';
const MAX_NAME_CHARS = 60;
const MAX_REASON_CHARS = 60;
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
// Message text (per kind, EN/ES). Reasons are per-plant data (machine_down_reasons.label_i18n, owner-edited, clean
// 1–60 chars); the built-in labels below (= src/locales machines.reasons.*) are only the fallback.
// The free-text details (machine_status_events.reason) never reach this function.

type Lang = 'en' | 'es';

export const REASONS: Record<Lang, Record<string, string>> = {
  en: {
    water_pump: 'Water pump',
    soap_dispenser: 'Soap dispenser',
    wont_start: "Won't start",
    leaking: 'Leaking',
    other: 'Other',
  },
  es: {
    water_pump: 'Bomba de agua',
    soap_dispenser: 'Dosificador de jabón',
    wont_start: 'No arranca',
    leaking: 'Gotea',
    other: 'Otro',
  },
};

export function pickLanguage(language: string | null): Lang {
  return language?.toLowerCase().split(/[-_]/)[0] === 'es' ? 'es' : 'en';
}

function labelFrom(labels: Record<string, unknown> | null | undefined, key: string): string | null {
  if (!labels || typeof labels !== 'object' || !Object.hasOwn(labels, key)) return null;
  const v = labels[key];
  if (typeof v !== 'string') return null;
  const clean = cleanText(v, MAX_REASON_CHARS);
  return clean || null;
}

/**
 * The reason in the recipient's language: the plant's label for that language, else the built-in
 * preset in that language, else the plant's English label; null when none exists (never echo the
 * code or the free-text details).
 */
export function reasonLabel(
  code: string | null,
  lang: Lang,
  labels?: Record<string, unknown> | null,
): string | null {
  if (code === null) return null;
  return (
    labelFrom(labels, lang) ??
    (Object.hasOwn(REASONS[lang], code) ? REASONS[lang][code] : null) ??
    labelFrom(labels, 'en')
  );
}

function cleanName(name: string): string {
  return cleanText(name, MAX_NAME_CHARS);
}

/** Control characters to spaces, spaces collapsed, length capped. Names and labels are setup data. */
function cleanText(text: string, max: number): string {
  const flat = Array.from(text, (ch) => {
    const c = ch.charCodeAt(0);
    return c < 0x20 || c === 0x7f ? ' ' : ch;
  })
    .join('')
    .replace(/ {2,}/g, ' ')
    .trim();
  return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
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

/** Spanish for the seeded washer names ("Washer 3" → "Lavadora 3"); other names are kept as entered. */
export function localMachineName(name: string, lang: Lang): string {
  const clean = cleanName(name);
  if (lang !== 'es') return clean;
  const m = /^Washer (\d{1,3})$/i.exec(clean);
  return m ? `Lavadora ${m[1]}` : clean;
}

function str(p: Record<string, unknown>, key: string): string | null {
  const v = Object.hasOwn(p, key) ? p[key] : undefined;
  return typeof v === 'string' && v.length > 0 ? v : null;
}

function labels(p: Record<string, unknown>, key: string): Record<string, unknown> | null {
  const v = Object.hasOwn(p, key) ? p[key] : undefined;
  return v !== null && typeof v === 'object' && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : null;
}

/** "since 9:42 PM" / "desde las 9:42 p. m."; null for an unreadable timestamp. */
function sinceText(iso: string | null, lang: Lang, timeZone: string): string | null {
  if (iso === null) return null;
  const time = formatTime(iso, lang, timeZone);
  if (time === null) return null;
  return lang === 'es'
    ? `desde ${hourIsOne(iso, timeZone) ? 'la' : 'las'} ${time}`
    : `since ${time}`;
}

const capitalize = (t: string) => (t ? t.charAt(0).toUpperCase() + t.slice(1) : t);

export interface BuildContext {
  now: Date;
  timeZone: string;
}

/**
 * One entry per push kind. isCurrent: false = the condition already ended (marked 'stale', not
 * sent). build: the notification in one language, or null when the payload is unusable.
 * Adding a kind = adding an entry here (and to the tests).
 */
export interface KindBuilder {
  isCurrent(payload: Record<string, unknown>): boolean;
  build(payload: Record<string, unknown>, lang: Lang, ctx: BuildContext): PushPayload | null;
}

export const BUILDERS: Record<string, KindBuilder> = {
  machine_down: {
    isCurrent: (p) => p.still_down === true,
    build(p, lang, ctx) {
      const id = str(p, 'machine_id');
      if (id === null) return null;
      const name =
        localMachineName(str(p, 'machine_name') ?? '', lang) ||
        (lang === 'es' ? 'Una máquina' : 'A machine');
      const title = lang === 'es' ? `${name} está fuera de servicio` : `${name} is down`;
      const reason = reasonLabel(str(p, 'reason_code'), lang, labels(p, 'reason_label_i18n'));
      const since = sinceText(str(p, 'down_since'), lang, ctx.timeZone);
      const body =
        reason === null ? capitalize(since ?? '') : [reason, since].filter(Boolean).join(' · ');
      return { title, body, tag: `machine-down-${id}`, url: ALERT_URL };
    },
  },
  washer_idle: {
    isCurrent: (p) => p.still_idle === true,
    build(p, lang, ctx) {
      const id = str(p, 'machine_id');
      if (id === null) return null;
      const name =
        localMachineName(str(p, 'machine_name') ?? '', lang) ||
        (lang === 'es' ? 'Una lavadora' : 'A washer');
      const idleSince = str(p, 'idle_since');
      const t = idleSince === null ? NaN : new Date(idleSince).getTime();
      const minutes = Number.isNaN(t) ? null : Math.floor((ctx.now.getTime() - t) / 60_000);
      const dur = minutes !== null && minutes >= 1 ? ` ${minutes} min` : '';
      const title =
        lang === 'es' ? `${name} parada${dur} — hay trabajo` : `${name} idle${dur} — work waiting`;
      const body = capitalize(sinceText(idleSince, lang, ctx.timeZone) ?? '');
      return { title, body, tag: `washer-idle-${id}`, url: ALERT_URL };
    },
  },
  task_assigned: {
    // The DB only hands out task_assigned (first push and reminders) while the task is open.
    isCurrent: () => true,
    build(p, lang) {
      const id = str(p, 'task_id');
      if (id === null) return null;
      const reminder = (num(p, 'reminder') ?? 0) > 0;
      const title = reminder
        ? lang === 'es'
          ? 'Recordatorio: tarea pendiente'
          : 'Reminder: task still open'
        : lang === 'es'
          ? 'Nueva tarea'
          : 'New task';
      return { title, body: taskText(p), tag: `task-${id}`, url: TASKS_URL };
    },
  },
  task_done: {
    isCurrent: () => true,
    build(p, lang, ctx) {
      const id = str(p, 'task_id');
      if (id === null) return null;
      const title = lang === 'es' ? 'Tarea hecha' : 'Task done';
      const doneIso = str(p, 'done_at');
      const time = doneIso === null ? null : formatTime(doneIso, lang, ctx.timeZone);
      const done =
        time === null || doneIso === null
          ? null
          : lang === 'es'
            ? `hecha a ${hourIsOne(doneIso, ctx.timeZone) ? 'la' : 'las'} ${time}`
            : `done ${time}`;
      const text = taskText(p, MAX_TASK_CHARS - 25);
      const body = text ? [text, done].filter(Boolean).join(' · ') : capitalize(done ?? '');
      // the done note and any names are never in the payload or the push
      return { title, body, tag: `task-${id}`, url: TASKS_URL };
    },
  },
  route_loaded: {
    // A route that was loaded stays loaded news; a correction is a new event, never stale.
    isCurrent: () => true,
    build(p, lang, ctx) {
      const id = str(p, 'route_id');
      const date = str(p, 'load_date');
      if (id === null || date === null || !/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;
      const name =
        localRouteName(str(p, 'route_name') ?? '', lang) ||
        (lang === 'es' ? 'Una ruta' : 'A route');
      const title = lang === 'es' ? `${name} cargada` : `${name} loaded`;
      const truck = formatWallTime(str(p, 'load_time') ?? '', lang);
      const loadedAtIso = str(p, 'loaded_at');
      const loadedAt = loadedAtIso === null ? null : formatTime(loadedAtIso, lang, ctx.timeZone);
      const parts =
        lang === 'es'
          ? [
              truck && `camión de las ${truck}`,
              loadedAt &&
                `cargada a ${loadedAtIso && hourIsOne(loadedAtIso, ctx.timeZone) ? 'la' : 'las'} ${loadedAt}`,
            ]
          : [truck && `${truck} truck`, loadedAt && `loaded ${loadedAt}`];
      const body = capitalize(parts.filter((x): x is string => !!x).join(' · '));
      return { title, body, tag: `route-${id}-${date}`, url: LOAD_OUT_URL };
    },
  },
};

/** Spanish for the seeded route names ("Route 21" → "Ruta 21"); other names are kept as entered. */
export function localRouteName(name: string, lang: Lang): string {
  const clean = cleanName(name);
  if (lang !== 'es') return clean;
  const m = /^Route (\w{1,10})$/i.exec(clean);
  return m ? `Ruta ${m[1]}` : clean;
}

/** A plant-local wall-clock time ("03:30" / "03:30:00") as "3:30 AM" / "3:30 a. m."; null if unreadable. */
export function formatWallTime(hhmm: string, lang: Lang): string | null {
  const m = /^(\d{2}):(\d{2})(?::\d{2}(?:\.\d+)?)?$/.exec(hhmm);
  if (!m || Number(m[1]) > 23 || Number(m[2]) > 59) return null;
  const d = new Date(Date.UTC(2000, 0, 1, Number(m[1]), Number(m[2])));
  return new Intl.DateTimeFormat(lang === 'es' ? 'es-US' : 'en-US', {
    hour: 'numeric',
    minute: '2-digit',
    timeZone: 'UTC',
  }).format(d);
}

const LOAD_OUT_URL = '/control';
const TASKS_URL = '/control/tasks';
const MAX_TASK_CHARS = 120;

function num(p: Record<string, unknown>, key: string): number | null {
  const v = Object.hasOwn(p, key) ? p[key] : undefined;
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}

/** The task's own text (the only free text a push may carry: to its assignees and owners). */
function taskText(p: Record<string, unknown>, max = MAX_TASK_CHARS): string {
  return cleanText(str(p, 'body') ?? '', max);
}

/** The notification for one claimed row, or null (unknown kind or unusable payload: never sent). */
export function buildMessage(
  kind: string,
  payload: Record<string, unknown> | null,
  language: string | null,
  ctx: BuildContext = { now: new Date(), timeZone: PLANT_TIME_ZONE },
): PushPayload | null {
  if (!Object.hasOwn(BUILDERS, kind) || payload === null || typeof payload !== 'object')
    return null;
  return BUILDERS[kind].build(payload, pickLanguage(language), ctx);
}

// ---------------------------------------------------------------------------------------------
// Claim → send → mark

export interface AlertGroup {
  alertId: string;
  kind: string;
  payload: Record<string, unknown> | null;
  /** One row per subscription (duplicates of the same subscription dropped). */
  rows: ClaimedRow[];
}

export function groupByAlert(rows: ClaimedRow[]): AlertGroup[] {
  const groups = new Map<string, AlertGroup>();
  for (const row of rows) {
    let g = groups.get(row.alert_id);
    if (!g) {
      g = { alertId: row.alert_id, kind: row.kind, payload: row.payload, rows: [] };
      groups.set(row.alert_id, g);
    }
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
 * marks EVERY claimed alert: the subscription ids that got the push, or 'stale' (the condition
 * already ended), 'failed' (every send failed) or 'none' (unknown kind, unusable payload, or no
 * allowed endpoint).
 */
export async function run(deps: Deps, now: () => Date = () => new Date()): Promise<RunCounts> {
  const counts: RunCounts = {
    alerts: 0,
    sent: 0,
    failed: 0,
    revoked: 0,
    stale: 0,
    skipped: 0,
    unsupported: 0,
    unmarked: 0,
  };
  const groups = groupByAlert(await deps.claim());
  counts.alerts = groups.length;
  const ctx: BuildContext = { now: now(), timeZone: PLANT_TIME_ZONE };

  for (const group of groups) {
    let recipients: string[];
    try {
      const builder = Object.hasOwn(BUILDERS, group.kind) ? BUILDERS[group.kind] : null;
      const payload =
        group.payload !== null && typeof group.payload === 'object' ? group.payload : null;
      if (builder === null || payload === null) {
        counts.unsupported++;
        recipients = ['none'];
      } else if (!builder.isCurrent(payload)) {
        counts.stale++;
        recipients = ['stale'];
      } else {
        const messages = new Map<Lang, PushPayload | null>();
        const messageFor = (language: string | null) => {
          const lang = pickLanguage(language);
          if (!messages.has(lang)) messages.set(lang, builder.build(payload, lang, ctx));
          return messages.get(lang) ?? null;
        };
        const sentIds: string[] = [];
        let attempted = 0;
        let unusable = false;
        await pool(group.rows, SEND_CONCURRENCY, async (row) => {
          if (!isAllowedPushEndpoint(row.endpoint)) {
            counts.skipped++;
            return;
          }
          const message = messageFor(row.language);
          if (message === null) {
            unusable = true;
            return;
          }
          attempted++;
          let result: SendResult;
          try {
            result = await deps.send(
              { endpoint: row.endpoint, p256dh: row.p256dh, auth: row.auth },
              message,
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
        if (unusable && attempted === 0) counts.unsupported++;
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
