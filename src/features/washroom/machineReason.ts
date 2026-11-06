// Machine-down reasons (owner 2026-11-05): plant DATA in machine_down_reasons (code + label per
// language + requires_details), owner-editable in Setup. The locale strings
// (machines.reasons.<code>) are only a fallback for the 5 default codes, e.g. when the list can't be
// loaded. Details: 1–200 characters, no control characters; required when the reason says so
// ("other"). The form asks people to describe the problem, not the person. Pure module.

import { localize, type I18nMap } from '../../lib/localize';

export type ReasonCode = string;

/** The 5 default reasons every plant starts with (fallback when the plant's list is unavailable). */
export const DEFAULT_REASON_CODES: readonly ReasonCode[] = [
  'water_pump',
  'soap_dispenser',
  'wont_start',
  'leaking',
  'other',
];

export const REASON_MAX = 200;

export interface ReasonOption {
  code: string;
  /** Label in the viewer's language. */
  label: string;
  requiresDetails: boolean;
}

export type ReasonResult =
  | { ok: true; code: ReasonCode; details: string | null }
  | { ok: false; error: 'pick' | 'details' | 'tooLong' };

/** Cleans the details and checks the server's rules. */
export function buildDownReason(
  code: ReasonCode | null,
  details: string,
  requiresDetails: boolean = code === 'other',
): ReasonResult {
  if (!code) return { ok: false, error: 'pick' };
  const extra = details
    // eslint-disable-next-line no-control-regex -- strip control characters the server would refuse
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (requiresDetails && !extra) return { ok: false, error: 'details' };
  if (extra.length > REASON_MAX) return { ok: false, error: 'tooLong' };
  return { ok: true, code, details: extra || null };
}

/** label_i18n jsonb → a string map (non-string values ignored). */
export function asLabelMap(value: unknown): I18nMap | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const out: I18nMap = {};
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    if (typeof v === 'string' && v.trim()) out[k] = v;
  }
  return Object.keys(out).length > 0 ? out : null;
}

/**
 * A reason's label in `lang`: the plant's label_i18n (then English), else the locale fallback for a
 * default code, else the code itself.
 */
export function reasonLabel(
  code: string,
  labelI18n: unknown,
  lang: string,
  fallback: (code: string) => string | null,
): string {
  const map = asLabelMap(labelI18n);
  if (map) return localize(map.en ?? code, map, lang);
  return fallback(code) ?? code;
}

/**
 * The text a viewer reads: the reason in their language, then the details ("Water pump: grinding
 * noise"). A reason that requires details ("other") shows the details alone. A row from before reason
 * codes shows its old text.
 */
export function reasonText(
  code: string | null | undefined,
  details: string | null | undefined,
  label: (code: string) => string,
): string | null {
  const d = details?.trim() || null;
  if (!code) return d;
  if (code === 'other') return d ?? label('other');
  return d ? `${label(code)}: ${d}` : label(code);
}

/**
 * A stable code for a new reason, from its English label: lowercase ASCII words joined with "_",
 * matching the DB rule ^[a-z][a-z0-9_]{1,39}$, unique in the plant ("_2", "_3"… when taken).
 */
export function codeFromLabel(label: string, existing: readonly string[]): string {
  let base = label
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 34);
  if (!/^[a-z]/.test(base)) base = `r_${base}`.replace(/_+$/, '');
  if (base.length < 2) base = 'reason';
  const taken = new Set(existing);
  if (!taken.has(base)) return base;
  for (let i = 2; ; i++) {
    const c = `${base}_${i}`;
    if (!taken.has(c)) return c;
  }
}

/**
 * Moves `id` one step up or down and returns the sort_order updates needed (orders become
 * 10, 20, 30… in the new order; only rows whose order changes are returned).
 */
export function reorderUpdates<T extends { id: string; sort_order: number }>(
  rows: readonly T[],
  id: string,
  dir: 'up' | 'down',
): { id: string; sort_order: number }[] {
  const list = [...rows].sort((a, b) => a.sort_order - b.sort_order);
  const i = list.findIndex((r) => r.id === id);
  const j = dir === 'up' ? i - 1 : i + 1;
  if (i < 0 || j < 0 || j >= list.length) return [];
  [list[i], list[j]] = [list[j] as T, list[i] as T];
  return list
    .map((r, n) => ({ id: r.id, sort_order: (n + 1) * 10, old: r.sort_order }))
    .filter((r) => r.sort_order !== r.old)
    .map(({ id: rid, sort_order }) => ({ id: rid, sort_order }));
}
