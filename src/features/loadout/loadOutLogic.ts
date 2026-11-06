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
