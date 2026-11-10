// Owner dashboard math (owner 2026-11-09: "I'm a visual guy, I like seeing numbers, in charts").
// Pure module. Only real data: estimates (≈, owner factors), washer status, washer taps and finished
// goods. Never weights, never per-person rows or totals, never invented targets.

import { round2 } from '../estimates/estimateMath';
import { isOffQueueReason, OFF_QUEUE_REASONS, type OffQueueReason } from '../washroom/offQueue';

/** Newest and oldest entry times (ms) of the current estimates; null when there are none. */
export function estimateAges(
  estimates: Iterable<{ entered_at: string; freshness: string | null; qty: number }>,
): { newest: number; oldest: number; old: number } | null {
  let newest = -Infinity;
  let oldest = Infinity;
  let old = 0;
  for (const e of estimates) {
    const at = Date.parse(e.entered_at);
    if (Number.isNaN(at)) continue;
    newest = Math.max(newest, at);
    oldest = Math.min(oldest, at);
    // Only estimates with work waiting matter for "check again".
    if ((e.freshness === 'amber' || e.freshness === 'red') && Number(e.qty) > 0) old += 1;
  }
  return Number.isFinite(newest) ? { newest, oldest, old } : null;
}

export type WasherState = 'running' | 'ready' | 'idle' | 'down';

export interface WasherCounts {
  running: number;
  ready: number;
  idle: number;
  down: number;
  total: number;
}

/** Counts per state. Down wins over everything; an unknown status counts as idle. */
export function washerCounts(rows: readonly { isDown: boolean; status: string }[]): WasherCounts {
  const c: WasherCounts = { running: 0, ready: 0, idle: 0, down: 0, total: rows.length };
  for (const r of rows) {
    if (r.isDown) c.down += 1;
    else if (r.status === 'running') c.running += 1;
    else if (r.status === 'ready') c.ready += 1;
    else c.idle += 1;
  }
  return c;
}

export const WASHER_STATES: readonly WasherState[] = ['running', 'ready', 'idle', 'down'];

/** Segments of the washer bar: only states with washers, with their share in %. */
export function washerSegments(
  c: WasherCounts,
): { state: WasherState; count: number; pct: number }[] {
  if (c.total === 0) return [];
  return WASHER_STATES.filter((s) => c[s] > 0).map((s) => ({
    state: s,
    count: c[s],
    pct: (c[s] / c.total) * 100,
  }));
}

/** One row of get_wash_group_pace (only the columns used here). */
export interface PaceInput {
  production_date: string;
  wash_group_id: string;
  wash_group_name: string;
  wash_group_name_i18n: unknown;
  color_hex: string | null;
  loads_run: number;
  standard_loads: number;
  rewash_loads: number;
}

export interface LoadsToday {
  productionDate: string | null;
  standard: number;
  rewash: number;
  groups: {
    id: string;
    name: string;
    nameI18n: unknown;
    color: string | null;
    standard: number;
    rewash: number;
  }[];
}

/** Loads washed this production day: totals and per group (groups with any load), most first. */
export function loadsToday(rows: readonly PaceInput[]): LoadsToday {
  const groups = rows
    .filter((r) => Number(r.loads_run) > 0 || Number(r.rewash_loads) > 0)
    .map((r) => ({
      id: r.wash_group_id,
      name: r.wash_group_name,
      nameI18n: r.wash_group_name_i18n,
      color: r.color_hex,
      standard: round2(Number(r.standard_loads)),
      rewash: Number(r.rewash_loads),
    }))
    .sort((a, b) => b.standard - a.standard || b.rewash - a.rewash || a.name.localeCompare(b.name));
  return {
    productionDate: rows[0]?.production_date ?? null,
    standard: round2(groups.reduce((s, g) => s + g.standard, 0)),
    rewash: groups.reduce((s, g) => s + g.rewash, 0),
    groups,
  };
}

/** One row of get_finished_goods_entries (only the columns used here; names are never read). */
export interface FinishedInput {
  item_type_id: string;
  item_name: string;
  item_name_i18n: unknown;
  pieces: number;
  voided_at: string | null;
}

export interface FinishedToday {
  pieces: number;
  entries: number;
  voided: number;
  items: { id: string; name: string; nameI18n: unknown; pieces: number }[];
}

/** Pieces finished per item this production day. Voided entries are left out of every total. */
export function finishedToday(rows: readonly FinishedInput[]): FinishedToday {
  const byItem = new Map<string, FinishedToday['items'][number]>();
  let voided = 0;
  let entries = 0;
  for (const r of rows) {
    if (r.voided_at) {
      voided += 1;
      continue;
    }
    entries += 1;
    const cur = byItem.get(r.item_type_id);
    if (cur) cur.pieces += Number(r.pieces);
    else
      byItem.set(r.item_type_id, {
        id: r.item_type_id,
        name: r.item_name,
        nameI18n: r.item_name_i18n,
        pieces: Number(r.pieces),
      });
  }
  const items = [...byItem.values()].sort(
    (a, b) => b.pieces - a.pieces || a.name.localeCompare(b.name),
  );
  return { pieces: items.reduce((s, i) => s + i.pieces, 0), entries, voided, items };
}

/** Our own wash groups only (no outside customer): what the estimate totals and charts count. */
export function ownGroups<T extends { id: string }>(
  groups: readonly T[],
  customerOf: (groupId: string) => string | null,
): T[] {
  return groups.filter((g) => !customerOf(g.id));
}

/** The first `n` rows and what's left ("+ 12 more"). */
export function topN<T>(rows: readonly T[], n: number): { shown: T[]; rest: number } {
  return { shown: rows.slice(0, n), rest: Math.max(0, rows.length - n) };
}

/** Bar length in % of the largest value; a value above 0 always shows at least a sliver. */
export function barPct(value: number, max: number): number {
  if (!(max > 0) || !(value > 0)) return 0;
  return Math.max(2, Math.min(100, (value / max) * 100));
}

function channel(c: number): number {
  const s = c / 255;
  return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
}

/** WCAG relative luminance of #RRGGBB; null for anything else. */
export function luminance(hex: string): number | null {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);
  if (!m) return null;
  const [r, g, b] = [m[1], m[2], m[3]].map((x) => channel(parseInt(x ?? '0', 16)));
  return 0.2126 * (r ?? 0) + 0.7152 * (g ?? 0) + 0.0722 * (b ?? 0);
}

export function contrast(a: string, b: string): number | null {
  const la = luminance(a);
  const lb = luminance(b);
  if (la === null || lb === null) return null;
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/**
 * Wash group colors are the goods' colors (black napkins are #0A0A0A), so some vanish on the dark
 * card. Below 3:1 (WCAG non-text contrast) the bar gets an outline so it is still seen.
 */
export function needsOutline(hex: string, surface: string): boolean {
  const c = contrast(hex, surface);
  return c === null || c < 3;
}

/** One get_off_queue_starts row (owner 2026-11-09). No names: washer taps are anonymous. */
export interface OffQueueInput {
  reason: string;
  starts: number | null;
  last_at: string | null;
}

export interface OffQueueToday {
  total: number;
  /** Always the four reasons, in the database order (not ready, wrong washer, urgent, other). */
  reasons: { reason: OffQueueReason; starts: number }[];
  /** Latest off-queue start (ms), null when none. */
  lastAt: number | null;
}

/** Today's off-queue starts: total and per reason. Unknown reason codes are left out. */
export function offQueueToday(rows: readonly OffQueueInput[]): OffQueueToday {
  const by = new Map<OffQueueReason, number>();
  let lastAt: number | null = null;
  for (const r of rows) {
    if (!isOffQueueReason(r.reason)) continue;
    const n = Math.max(0, Math.trunc(Number(r.starts ?? 0)) || 0);
    by.set(r.reason, (by.get(r.reason) ?? 0) + n);
    const t = r.last_at ? Date.parse(r.last_at) : NaN;
    if (n > 0 && Number.isFinite(t)) lastAt = lastAt === null ? t : Math.max(lastAt, t);
  }
  const reasons = OFF_QUEUE_REASONS.map((reason) => ({ reason, starts: by.get(reason) ?? 0 }));
  return { total: reasons.reduce((a, r) => a + r.starts, 0), reasons, lastAt };
}
