// Estimate math for the soil-estimate screen (PRD B1; owner 2026-11-04 rounds 1–3). Pure module.
// Loads per full container are owner estimates, so every converted number is approximate ("≈");
// a missing factor gives null, never a guess (CLAUDE.md measurement model). The DB's app.to_loads is
// authoritative; this is the live preview on the card.

export type EstimateUnit = 'load' | 'basket' | 'bin';

export interface GroupFactors {
  allow_basket_estimates: boolean;
  allow_bin_estimates: boolean;
  loads_per_basket: number | null;
  loads_per_bin: number | null;
}

/** Containers offered for a group: loads always; basket / bin only where allowed. */
export function estimateUnits(g: GroupFactors): EstimateUnit[] {
  return [
    ...(g.allow_bin_estimates ? (['bin'] as const) : []),
    ...(g.allow_basket_estimates ? (['basket'] as const) : []),
    'load',
  ];
}

/** The container a card starts on: the last estimate's unit if still allowed, else the first. */
export function defaultUnit(g: GroupFactors, lastUnit: string | null | undefined): EstimateUnit {
  const units = estimateUnits(g);
  return (units as string[]).includes(lastUnit ?? '')
    ? (lastUnit as EstimateUnit)
    : (units[0] ?? 'load');
}

/** Loads for an amount; null when the container has no factor. */
export function toLoads(qty: number, unit: EstimateUnit, g: GroupFactors): number | null {
  if (unit === 'load') return qty;
  const f = unit === 'bin' ? g.loads_per_bin : g.loads_per_basket;
  return f ? round2(qty * f) : null;
}

/** Hours of washing on ONE washer: loads × the group's formula cycle minutes; null without either. */
export function washHours(
  loads: number | null,
  cycleMinutes: number | null | undefined,
): number | null {
  if (loads === null || !cycleMinutes) return null;
  return (loads * cycleMinutes) / 60;
}

export function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

/**
 * Bin fill = full containers + one partly full container (coordinator 2026-11-04 UX round):
 * "Full bins: [−] 2 [+]" and "Plus a partial bin: none / ¼ / ½ / ¾". 2 full + ½ = 2½.
 */
export interface Fill {
  full: number;
  part: number; // 0 (none), 0.25, 0.5 or 0.75
}

export const PARTIALS = [0, 0.25, 0.5, 0.75] as const;

export function fillAmount(f: Fill): number {
  return f.full + f.part;
}

/**
 * A typed amount back to a fill: 2.5 → 2 full + ½; 3 → 3 full. A fraction that isn't a quarter
 * (2.3) has no partial pick: `part` keeps the exact remainder and no partial button is pressed.
 */
export function splitAmount(qty: number): Fill {
  if (qty <= 0) return { full: 0, part: 0 };
  const full = Math.floor(qty);
  return { full, part: round2(qty - full) };
}

/** Plus a partial container: none / ¼ / ½ / ¾. */
export function setPart(f: Fill, part: number): Fill {
  return { ...f, part };
}

/** The full-container stepper: never below 0. */
export function stepFull(f: Fill, delta: number): Fill {
  return { ...f, full: Math.max(0, f.full + delta) };
}

/**
 * Parses a typed amount ("2.5", "2,5"): 0–10,000 with at most 2 decimals, mirroring the server's
 * check_qty(qty, 0, 10000). 0 = nothing waiting. Null when invalid.
 */
export function parseAmount(input: string): number | null {
  const s = input.trim().replace(',', '.');
  if (!/^\d+(\.\d{1,2})?$/.test(s)) return null;
  const n = Number(s);
  return n <= 10000 ? n : null;
}

export interface SummaryInput {
  loads: number | null;
  cycleMinutes: number | null | undefined;
}

export interface Summary {
  /** ≈ loads waiting across groups with a known number. */
  loads: number;
  /** Groups with an amount but no number (missing factor): left out of the total, said on screen. */
  unknown: number;
  /** ≈ hours to wash it all on the working washers; null when there's no capacity or no data. */
  hours: number | null;
  /** Groups with loads but no formula time: in the loads total, missing from the hours. */
  noTime: number;
}

/**
 * Totals for the top of the screen. Hours = Σ(loads × cycle minutes) / 60 / capacity, where capacity
 * is the sum of the working (active, not down) washers' load factors (Washer 6 = 1.19).
 */
export function summarize(rows: readonly SummaryInput[], washerCapacity: number): Summary {
  let loads = 0;
  let unknown = 0;
  let minutes = 0;
  let minutesKnown = false;
  let noTime = 0;
  for (const r of rows) {
    if (r.loads === null) {
      unknown += 1;
      continue;
    }
    loads += r.loads;
    if (r.cycleMinutes && r.loads > 0) {
      minutes += r.loads * r.cycleMinutes;
      minutesKnown = true;
    } else if (r.loads > 0) {
      noTime += 1;
    }
  }
  const hours =
    washerCapacity > 0 && minutesKnown ? minutes / 60 / washerCapacity : loads === 0 ? 0 : null;
  return { loads: round2(loads), unknown, hours: hours === null ? null : round2(hours), noTime };
}

/** 2.25 h → { h: 2, m: 15 }, rounded to 5 minutes (it's an estimate). */
export function hoursMinutes(hours: number): { h: number; m: number } {
  const total = Math.round((hours * 60) / 5) * 5;
  return { h: Math.floor(total / 60), m: total % 60 };
}
