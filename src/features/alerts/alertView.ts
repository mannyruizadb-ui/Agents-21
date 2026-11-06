// The Alerts tab (coordinator 2026-11-06): one row per alert from get_my_alerts. This module turns a
// row's kind + payload (app.alert_payload: no names, no free text except a task's own text) into what
// the row shows and where a tap goes. Pure; the page renders it through t(). Unknown kinds and
// unusable payloads give null (never shown), the same rule as the push sender.

export type AlertKind =
  'machine_down' | 'washer_idle' | 'task_assigned' | 'task_done' | 'route_loaded';
export type AlertTone = 'danger' | 'warn' | 'info';

export interface AlertRow {
  alert_id: string;
  kind: string;
  created_at: string;
  payload: unknown;
  still_current: boolean;
  /** server: this user may clear it (it is over; live alerts can't be cleared). Absent on older servers. */
  can_clear?: boolean;
}

export interface AlertView {
  id: string;
  kind: AlertKind;
  createdAt: string;
  tone: AlertTone;
  /** where a tap goes */
  to: string;
  /** still needs someone: machine still down, washer still idle, task still open */
  open: boolean;
  /** the condition ended (machine fixed, load started, task done, loaded mark removed) */
  resolved: boolean;
  /** the Clear button shows (server decides; never for a live alert) */
  canClear: boolean;
  machineName?: string;
  areaName?: string;
  reasonCode?: string | null;
  reasonLabels?: unknown;
  since?: string | null;
  taskText?: string;
  routeName?: string;
  loadTime?: string | null;
  loadedAt?: string | null;
}

const MAX_TEXT = 200;

function str(p: Record<string, unknown>, key: string): string | null {
  const v = Object.hasOwn(p, key) ? p[key] : undefined;
  return typeof v === 'string' && v.trim() !== '' ? v : null;
}

function clean(s: string): string {
  return (
    s
      // eslint-disable-next-line no-control-regex -- strip control characters from stored text
      .replace(/[\u0000-\u001f\u007f]+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, MAX_TEXT)
  );
}

const UUIDISH = /^[0-9a-f-]{8,64}$/i;

export function describeAlert(row: AlertRow): AlertView | null {
  const p = row.payload;
  if (p === null || typeof p !== 'object' || Array.isArray(p)) return null;
  const payload = p as Record<string, unknown>;
  const base = { id: row.alert_id, createdAt: row.created_at, canClear: row.can_clear === true };
  switch (row.kind) {
    case 'machine_down': {
      const id = str(payload, 'machine_id');
      if (!id || !UUIDISH.test(id)) return null;
      return {
        ...base,
        kind: 'machine_down',
        tone: 'danger',
        to: `/control/machines?machine=${id}`,
        open: row.still_current,
        resolved: !row.still_current,
        machineName: clean(str(payload, 'machine_name') ?? ''),
        areaName: clean(str(payload, 'area_name') ?? ''),
        reasonCode: str(payload, 'reason_code'),
        reasonLabels: payload.reason_label_i18n ?? null,
        since: str(payload, 'down_since'),
      };
    }
    case 'washer_idle': {
      const id = str(payload, 'machine_id');
      if (!id || !UUIDISH.test(id)) return null;
      return {
        ...base,
        kind: 'washer_idle',
        tone: 'warn',
        to: '/control/washers',
        open: row.still_current,
        resolved: !row.still_current,
        machineName: clean(str(payload, 'machine_name') ?? ''),
        areaName: clean(str(payload, 'area_name') ?? ''),
        since: str(payload, 'idle_since'),
      };
    }
    case 'task_assigned':
      if (!str(payload, 'task_id')) return null;
      return {
        ...base,
        kind: 'task_assigned',
        tone: 'info',
        to: '/control/tasks',
        open: row.still_current,
        resolved: !row.still_current,
        taskText: clean(str(payload, 'body') ?? ''),
      };
    case 'task_done':
      if (!str(payload, 'task_id')) return null;
      return {
        ...base,
        kind: 'task_done',
        tone: 'info',
        to: '/control/tasks',
        open: false,
        resolved: false,
        taskText: clean(str(payload, 'body') ?? ''),
        since: str(payload, 'done_at'),
      };
    case 'route_loaded':
      if (!str(payload, 'route_id')) return null;
      return {
        ...base,
        kind: 'route_loaded',
        tone: 'info',
        to: '/control/load-out',
        open: false,
        // a loaded mark that was taken off again
        resolved: !row.still_current,
        routeName: clean(str(payload, 'route_name') ?? ''),
        loadTime: str(payload, 'load_time'),
        loadedAt: str(payload, 'loaded_at'),
      };
    default:
      return null;
  }
}

/** Open alerts first (newest first inside each group), then the rest, newest first. */
export function splitAlerts(rows: readonly AlertRow[]): {
  open: AlertView[];
  earlier: AlertView[];
} {
  const views = rows.map(describeAlert).filter((v): v is AlertView => v !== null);
  views.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  return { open: views.filter((v) => v.open), earlier: views.filter((v) => !v.open) };
}

/** Minutes between an ISO time and now (floored, never negative), or null when unreadable. */
export function minutesAgo(iso: string, nowMs: number): number | null {
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return null;
  return Math.max(0, Math.floor((nowMs - t) / 60_000));
}

/** "03:30" / "03:30:00" (plant wall clock) → a Date at that UTC time for Intl formatting, or null. */
export function wallTimeDate(hhmm: string | null | undefined): Date | null {
  const m = /^(\d{2}):(\d{2})(?::\d{2}(?:\.\d+)?)?$/.exec(hhmm ?? '');
  if (!m || Number(m[1]) > 23 || Number(m[2]) > 59) return null;
  return new Date(Date.UTC(2000, 0, 1, Number(m[1]), Number(m[2])));
}
