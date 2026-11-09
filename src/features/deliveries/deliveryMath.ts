// AA Linen deliveries (owner 2026-11-06 B): bins per wash group in quarters, 0–50. Pure module; the
// server (record_customer_delivery) is the final validator and app.to_loads the authoritative loads.

import { plantLocal, zonedToEpoch } from '../loadout/loadOutLogic';

export const MAX_BINS = 50;
export const BIN_STEP = 0.25;

/** Rounds to the nearest quarter and clamps to 0–50. */
export function clampBins(n: number): number {
  if (!Number.isFinite(n)) return 0;
  const q = Math.round(n * 4) / 4;
  return Math.min(MAX_BINS, Math.max(0, q));
}

/** One ± tap: a quarter bin up or down, never below 0 or above 50. */
export function stepBins(bins: number, direction: 1 | -1): number {
  return clampBins(bins + direction * BIN_STEP);
}

/** A ± tap of any size (+1, +½, −½): never below 0 or above 50, in quarters. */
export function addBins(bins: number, delta: number): number {
  return clampBins(bins + delta);
}

/**
 * What was typed → bins, or null when it is not 0–50 in quarters. Accepts "1.5", "1,5", "½", "1½",
 * "1 1/2" and "" (= 0).
 */
export function parseBins(text: string): number | null {
  const s = text.trim().replace(',', '.');
  if (s === '') return 0;
  const glyph: Record<string, number> = { '¼': 0.25, '½': 0.5, '¾': 0.75 };
  let n: number;
  const g = /^(\d+)?\s*([¼½¾])$/.exec(s);
  const f = /^(?:(\d+)\s+)?(\d)\/(\d)$/.exec(s);
  if (g) n = Number(g[1] ?? 0) + (glyph[g[2] as string] ?? 0);
  else if (f) {
    const den = Number(f[3]);
    if (den === 0) return null;
    n = Number(f[1] ?? 0) + Number(f[2]) / den;
  } else if (/^\d+(\.\d+)?$|^\.\d+$/.test(s)) n = Number(s);
  else return null;
  if (n < 0 || n > MAX_BINS || Math.abs(n * 4 - Math.round(n * 4)) > 1e-9) return null;
  return Math.round(n * 4) / 4;
}

/** Approximate loads for bins (null without loads_per_bin: "loads unknown", never a guess). */
export function binsToLoads(bins: number, loadsPerBin: number | null | undefined): number | null {
  if (!loadsPerBin || loadsPerBin <= 0) return null;
  return Math.round(bins * loadsPerBin * 100) / 100;
}

export interface DeliveryLine {
  washGroupId: string;
  bins: number;
}

/** The lines to send, in the given group order: only groups with more than 0 bins. */
export function deliveryLines(
  groupOrder: readonly string[],
  bins: Readonly<Record<string, number>>,
): DeliveryLine[] {
  return groupOrder.flatMap((id) => {
    const b = bins[id] ?? 0;
    return b > 0 ? [{ washGroupId: id, bins: clampBins(b) }] : [];
  });
}

/**
 * p_entered_at for a send: only when the entry waited more than 2 minutes on the phone (an offline
 * entry keeps its real time). A fresh entry lets the server use its own clock, so a phone clock that
 * runs ahead can never make the server refuse it.
 */
export function enteredAtParam(enteredAt: string | undefined, nowMs: number): string | undefined {
  if (!enteredAt) return undefined;
  const t = Date.parse(enteredAt);
  if (Number.isNaN(t)) return undefined;
  return nowMs - t > 2 * 60_000 ? enteredAt : undefined;
}

/** One line of get_customer_deliveries.lines (jsonb), checked. */
export interface HistoryLine {
  washGroupId: string;
  name: string;
  nameI18n: unknown;
  bins: number;
  loads: number | null;
  queueStatus: string | null;
}

/** get_customer_deliveries.lines → typed lines; anything unreadable is skipped. */
export function parseHistoryLines(value: unknown): HistoryLine[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((v): HistoryLine[] => {
    if (typeof v !== 'object' || v === null) return [];
    const o = v as Record<string, unknown>;
    const bins = Number(o.bins);
    if (typeof o.wash_group_id !== 'string' || !Number.isFinite(bins)) return [];
    const loads = o.loads === null || o.loads === undefined ? null : Number(o.loads);
    return [
      {
        washGroupId: o.wash_group_id,
        name: typeof o.wash_group_name === 'string' ? o.wash_group_name : '',
        nameI18n: o.wash_group_name_i18n ?? null,
        bins,
        loads: loads !== null && Number.isFinite(loads) ? loads : null,
        queueStatus: typeof o.queue_status === 'string' ? o.queue_status : null,
      },
    ];
  });
}

/** The start of the plant's current day (00:00 plant time) as an ISO instant (for p_since). */
export function plantDayStartIso(nowMs: number, timeZone: string): string {
  return new Date(zonedToEpoch(plantLocal(nowMs, timeZone).date, '00:00', timeZone)).toISOString();
}

/** True when `iso` falls on the plant's current day (plant time); false when unreadable. */
export function isPlantToday(iso: string, nowMs: number, timeZone: string): boolean {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return false;
  return plantLocal(t, timeZone).date === plantLocal(nowMs, timeZone).date;
}
