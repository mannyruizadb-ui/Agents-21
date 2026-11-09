import { localName } from '../../lib/seededNames';

// Load-out logic (owner 2026-11-06): load dates, routes per weekday, the countdown to the next truck,
// and which items are rows on the sheet. Times are the PLANT's local time (America/New_York for ADB).
// Pure module.

export interface RouteLike {
  id: string;
  load_time: string; // "03:30:00"
  days_of_week: number[]; // 0 = Sun … 6 = Sat
  active: boolean;
  sort_order?: number;
  name: string;
}

/** The plant-local date ("YYYY-MM-DD") and time ("HH:MM") of an instant. */
export function plantLocal(nowMs: number, timeZone: string): { date: string; time: string } {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(new Date(nowMs));
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '00';
  return {
    date: `${get('year')}-${get('month')}-${get('day')}`,
    time: `${get('hour')}:${get('minute')}`,
  };
}

export function addDays(date: string, days: number): string {
  const d = new Date(`${date}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export function weekday(date: string): number {
  return new Date(`${date}T12:00:00Z`).getUTCDay();
}

/** The next loading morning: today before noon (plant time), else tomorrow (same rule as the DB). */
export function nextLoadDate(nowMs: number, timeZone: string): string {
  const { date, time } = plantLocal(nowMs, timeZone);
  return time < '12:00' ? date : addDays(date, 1);
}

/** Active routes that run on `date`'s weekday, in load-time order. */
export function routesForDate<R extends RouteLike>(routes: readonly R[], date: string): R[] {
  const dow = weekday(date);
  return routes
    .filter((r) => r.active && r.days_of_week.includes(dow))
    .sort(
      (a, b) =>
        a.load_time.localeCompare(b.load_time) ||
        (a.sort_order ?? 0) - (b.sort_order ?? 0) ||
        a.name.localeCompare(b.name),
    );
}

/** "Same as yesterday": the latest earlier date (up to 7 days back) on which some route runs. */
export function previousLoadDate(routes: readonly RouteLike[], date: string): string | null {
  for (let i = 1; i <= 7; i++) {
    const d = addDays(date, -i);
    if (routesForDate(routes, d).length > 0) return d;
  }
  return null;
}

/**
 * "Same as last <weekday>" (review item 6, owner 2026-11-09): the same weekday one week earlier, so the
 * same routes run (Route 11 Mon/Thu, Route 5 Tue/Fri); "same as yesterday" copied the wrong routes.
 */
export function sameWeekdayLastWeek(date: string): string {
  return addDays(date, -7);
}

/** Plant-local date + "HH:MM[:SS]" → epoch ms (DST-safe, via the zone's offset at that moment). */
export function zonedToEpoch(date: string, time: string, timeZone: string): number {
  const [h = '0', m = '0'] = time.split(':');
  const guess = Date.parse(`${date}T${h.padStart(2, '0')}:${m.padStart(2, '0')}:00Z`);
  // The zone's offset at the guessed instant; one correction pass handles DST edges.
  const offset = (ms: number) => {
    const p = plantLocal(ms, timeZone);
    return Date.parse(`${p.date}T${p.time}:00Z`) - ms;
  };
  const first = guess - offset(guess);
  return guess - offset(first);
}

export interface TruckLike {
  route_id: string;
  name: string;
  load_time: string;
  loaded: boolean;
}

/** The next truck not loaded yet and its minutes from now (negative = late); null when all loaded. */
export function nextTruck<T extends TruckLike>(
  routes: readonly T[],
  loadDate: string,
  nowMs: number,
  timeZone: string,
): { route: T; minutes: number } | null {
  const open = routes
    .filter((r) => !r.loaded)
    .map((r) => ({ route: r, at: zonedToEpoch(loadDate, r.load_time, timeZone) }))
    .sort((a, b) => a.at - b.at);
  const first = open[0];
  return first ? { route: first.route, minutes: Math.round((first.at - nowMs) / 60000) } : null;
}

export interface ItemLike {
  id: string;
  name: string;
  sort_order: number;
  active: boolean;
}

/** Item names the owner asked for on the sheet (sheets, butcher coats by size, soil bags). */
const DEFAULT_ROW = /^(sheet|butcher coat|soil bag)/i;

/**
 * The sheet's item rows: the owner's default items, plus any item already used on a recent load-out,
 * plus rows added by hand, in the items' own order.
 */
export function loadOutRows<I extends ItemLike>(
  items: readonly I[],
  recentItemIds: ReadonlySet<string>,
  addedIds: ReadonlySet<string>,
): I[] {
  return items
    .filter(
      (i) =>
        i.active && (DEFAULT_ROW.test(i.name) || recentItemIds.has(i.id) || addedIds.has(i.id)),
    )
    .sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name));
}

/** Typed quantity → 0–100,000 whole number, or null. */
export function parseQty(input: string): number | null {
  const s = input.trim();
  if (s === '') return 0;
  if (!/^\d+$/.test(s)) return null;
  const n = Number(s);
  return n <= 100000 ? n : null;
}

/** Spanish for the seeded route names ("Route 21" → "Ruta 21"); see src/lib/seededNames.ts. */
export function localRouteName(name: string, lang: string): string {
  return localName('route', name, lang);
}

/** Minutes from now until a route's truck time on the load date (negative = late). */
export function minutesUntil(
  loadDate: string,
  loadTime: string,
  nowMs: number,
  timeZone: string,
): number {
  return Math.round((zonedToEpoch(loadDate, loadTime, timeZone) - nowMs) / 60000);
}

/** A plant wall-clock time ("03:30" / "03:30:00") as "3:30 AM" / "3:30 a. m."; the raw text if unreadable. */
export function wallClock(hhmm: string, lang: string): string {
  const m = /^(\d{2}):(\d{2})/.exec(hhmm);
  if (!m || Number(m[1]) > 23 || Number(m[2]) > 59) return hhmm;
  return new Intl.DateTimeFormat(lang, {
    hour: 'numeric',
    minute: '2-digit',
    timeZone: 'UTC',
  }).format(new Date(Date.UTC(2000, 0, 1, Number(m[1]), Number(m[2]))));
}

const SIZE_SUFFIX = /^(.+?)\s+(XXS|XS|S|M|L|XL|XXL|2XL|3XL|4XL)$/i;

/** "Butcher coat XL" → { base: "Butcher coat", size: "XL" }; null when the name has no size. */
export function splitSize(name: string): { base: string; size: string } | null {
  const m = SIZE_SUFFIX.exec(name.trim());
  return m?.[1] && m[2] ? { base: m[1], size: m[2].toUpperCase() } : null;
}

export type RowGroup<I> =
  { kind: 'single'; item: I } | { kind: 'sizes'; base: string; items: { item: I; size: string }[] };

/**
 * Sheet rows with sized items of the same base ("Butcher coat M / L / XL") under one heading, at the
 * first one's place. A base with one size stays a single row. Order inside a group = row order.
 */
export function groupSizes<I extends { name: string }>(rows: readonly I[]): RowGroup<I>[] {
  const byBase = new Map<string, { item: I; size: string }[]>();
  for (const item of rows) {
    const s = splitSize(item.name);
    if (!s) continue;
    const key = s.base.toLowerCase();
    byBase.set(key, [...(byBase.get(key) ?? []), { item, size: s.size }]);
  }
  const out: RowGroup<I>[] = [];
  const placed = new Set<string>();
  for (const item of rows) {
    const s = splitSize(item.name);
    const group = s ? byBase.get(s.base.toLowerCase()) : undefined;
    if (!s || !group || group.length < 2) {
      out.push({ kind: 'single', item });
      continue;
    }
    const key = s.base.toLowerCase();
    if (placed.has(key)) continue;
    placed.add(key);
    out.push({ kind: 'sizes', base: s.base, items: group });
  }
  return out;
}

/** Minutes before a truck's time that the nav badge starts counting it (review 2026-11-09 #10). */
export const BADGE_LEAD_MINUTES = 60;

/**
 * The nav badge on Load-out: routes not loaded yet, with something to load, whose truck time is
 * within `leadMinutes` from now or already past (late). A badge that is on from 3 PM, 12 hours
 * before the first truck, gets ignored; this one shows only when it matters.
 */
export function loadOutBadgeCount<T extends TruckLike & { lines: readonly unknown[] }>(
  routes: readonly T[],
  loadDate: string,
  nowMs: number,
  timeZone: string,
  leadMinutes = BADGE_LEAD_MINUTES,
): number {
  return routes.filter(
    (r) =>
      !r.loaded &&
      r.lines.length > 0 &&
      minutesUntil(loadDate, r.load_time, nowMs, timeZone) <= leadMinutes,
  ).length;
}
