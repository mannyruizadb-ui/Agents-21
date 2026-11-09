// Pure helpers for the owner Setup tables (machines, wash groups, formulas; review 2026-11-09 item 8).
// They mirror the DB CHECKs so the owner gets a clear message before saving; the database stays the
// final validator (setupErrors.ts maps what it refuses).
import { cleanName } from './setupErrors';

/** Typed decimal ("3.5", "3,5", "") → number in (0, max] with ≤ `decimals` places; null = blank. */
export function parseDecimal(
  input: string,
  max: number,
  decimals: number,
  min = 0,
  minInclusive = false,
): number | null | 'invalid' {
  const s = input.trim().replace(',', '.');
  if (s === '') return null;
  if (!/^\d{0,4}(\.\d+)?$/.test(s) || s === '.') return 'invalid';
  const [, frac = ''] = s.split('.');
  if (frac.length > decimals) return 'invalid';
  const n = Number(s);
  if (!Number.isFinite(n)) return 'invalid';
  if (minInclusive ? n < min : n <= min) return 'invalid';
  return n <= max ? n : 'invalid';
}

/** Loads per basket / per bin: wash_groups numeric(7,3), (0, 20] (20261109215626). */
export const parseLoadsPer = (input: string) => parseDecimal(input, 20, 3);

/** A washer's load factor: machines CHECK 0.25–4.00, two decimals. Blank is not allowed. */
export function parseLoadFactor(input: string): number | 'invalid' {
  const v = parseDecimal(input, 4, 2, 0.25, true);
  return v === null ? 'invalid' : v;
}

/** Cycle minutes: wash_formulas CHECK 1–300, whole minutes; null = blank (unknown). */
export function parseMinutes(input: string): number | null | 'invalid' {
  const s = input.trim();
  if (s === '') return null;
  if (!/^\d{1,3}$/.test(s)) return 'invalid';
  const n = Number(s);
  return n >= 1 && n <= 300 ? n : 'invalid';
}

/** Formula number as shown on the washer: 1–20 characters (wash_formulas CHECK). */
export const cleanFormulaNo = (input: string) => cleanName(input, 20);

/** Value → text for an input ("" for null). */
export function numText(v: number | null | undefined): string {
  return v === null || v === undefined ? '' : String(v);
}

/** The other languages' names → name_i18n: empty ones left out; null if one is too long. */
export function toNameI18n(
  names: Readonly<Record<string, string>>,
  langs: readonly string[],
): Record<string, string> | null {
  const out: Record<string, string> = {};
  for (const lang of langs) {
    const raw = names[lang] ?? '';
    if (raw.trim() === '') continue;
    const v = cleanName(raw);
    if (!v) return null;
    out[lang] = v;
  }
  return out;
}

/** name_i18n (jsonb) → editable text per language. */
export function fromNameI18n(value: unknown, langs: readonly string[]): Record<string, string> {
  const map = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  const out: Record<string, string> = {};
  for (const lang of langs) {
    const v = (map as Record<string, unknown>)[lang];
    out[lang] = typeof v === 'string' ? v : '';
  }
  return out;
}

/**
 * The languages to edit next to the base name: the plant's enabled languages that the app has a
 * locale file for, minus the default (the base `name` is in the plant's default language).
 */
export function otherLanguages(
  enabled: readonly string[] | undefined,
  defaultLang: string,
  available: readonly string[],
): string[] {
  const pool = enabled && enabled.length > 0 ? enabled : available;
  return pool.filter((l) => l !== defaultLang && available.includes(l));
}

export type EstimateUnit = 'load' | 'basket' | 'bin';

export interface FactorFields {
  loads_per_basket: number | null;
  loads_per_bin: number | null;
  allow_basket_estimates: boolean;
  allow_bin_estimates: boolean;
  default_estimate_unit: EstimateUnit;
}

/** What the DB CHECKs would refuse, as message keys (empty = fine). */
export function factorProblems(f: FactorFields): string[] {
  const out: string[] = [];
  if (f.allow_basket_estimates && f.loads_per_basket === null)
    out.push('setup.groups.errors.basketNeedsFactor');
  if (f.allow_bin_estimates && f.loads_per_bin === null)
    out.push('setup.groups.errors.binNeedsFactor');
  if (f.default_estimate_unit === 'basket' && !f.allow_basket_estimates)
    out.push('setup.groups.errors.defaultBasket');
  if (f.default_estimate_unit === 'bin' && !f.allow_bin_estimates)
    out.push('setup.groups.errors.defaultBin');
  return out;
}

export interface MissingFactorRow {
  customer_id: string | null;
  active: boolean;
  loads_per_bin: number | null;
  allow_bin_estimates: boolean;
}

/**
 * Is this group's "loads per bin" missing where it matters? A customer's (AA Linen) goods always
 * arrive in bins, so a blank there means "loads unknown" on every drop-off. Our own groups only
 * need it when bins are allowed (the DB already requires it then), so a blank is fine for them.
 */
export function binFactorMissing(g: MissingFactorRow): boolean {
  return g.active && g.customer_id !== null && g.loads_per_bin === null;
}

/** The next sort_order after the existing ones (steps of 10, like the seed). */
export function nextSortOrder(orders: readonly number[]): number {
  return orders.length === 0 ? 10 : Math.max(...orders) + 10;
}
