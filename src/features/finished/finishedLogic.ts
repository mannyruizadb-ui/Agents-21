import type { KeyValueStore } from '../../lib/scopedStore';

// Finished-goods entry (owner 2026-11-10): the finishing manager logs output CONTINUOUSLY through the
// shift, one line per tap ("every entry ADDS a line"; corrections are void-one-line + re-enter). Pure
// helpers for the entry screen and its end-of-shift review: which items finishing counts, the picker
// groups, the amount preview, the double-tap and big-number checks, pace per hour (per ITEM per shift,
// never per person), and the per-device "working on" list. Pure except load/save through a store.

/** The item_types columns the screen reads. */
export interface FinishItem {
  id: string;
  name: string;
  name_i18n: unknown;
  category: string;
  count_mode: 'pack' | 'unit';
  pack_size: number | null;
  bin_size: number | null;
  color_hex: string;
  sort_order: number;
  active: boolean;
  washed: boolean;
}

/** Item categories finishing counts: linens, towels, aprons & coats. Mats and mops are not finishing's. */
export const FINISHING_CATEGORIES = ['linen', 'towel', 'apparel'] as const;

/** Picker chips, in order. */
export const FINISH_GROUPS = [
  'napkins',
  'tablecloths',
  'sheets',
  'towels',
  'apparel',
  'other',
] as const;
export type FinishGroup = (typeof FINISH_GROUPS)[number];

export function isFinishingItem(i: Pick<FinishItem, 'category' | 'washed' | 'active'>): boolean {
  return i.washed && i.active && (FINISHING_CATEGORIES as readonly string[]).includes(i.category);
}

/** The picker chip of an item: from its category, and for linens from its name. */
export function finishGroupOf(i: Pick<FinishItem, 'category' | 'name'>): FinishGroup {
  if (i.category === 'towel') return 'towels';
  if (i.category === 'apparel') return 'apparel';
  const n = i.name.trim().toLowerCase();
  if (n.startsWith('napkin')) return 'napkins';
  if (n.startsWith('tablecloth')) return 'tablecloths';
  if (n.startsWith('sheet')) return 'sheets';
  return 'other';
}

/** Is this a pack item (packs × pack size + loose)? Otherwise one count of pieces. */
export function isPackItem(i: Pick<FinishItem, 'count_mode' | 'pack_size'>): boolean {
  return i.count_mode === 'pack' && i.pack_size !== null && i.pack_size > 0;
}

/** One entry before it is sent: what record_finished_goods gets. */
export interface Amount {
  packs: number;
  loose: number;
  /** The pack size the person saw (pack items); null for unit items. */
  packSize: number | null;
}

/** Preview only: the DB computes pieces (generated column) and its value is authoritative. */
export function previewPieces(a: Amount): number {
  return a.packs * (a.packSize ?? 0) + a.loose;
}

/** "+1 bin": the bin's pieces go in as loose pieces (client arithmetic; the DB keeps packs 0). */
export function binAmount(i: FinishItem): Amount | null {
  if (i.bin_size === null) return null;
  return { packs: 0, loose: i.bin_size, packSize: isPackItem(i) ? i.pack_size : null };
}

export function packsAmount(i: FinishItem, packs: number): Amount {
  return { packs, loose: 0, packSize: i.pack_size };
}

export function looseAmount(i: FinishItem, loose: number): Amount {
  return { packs: 0, loose, packSize: isPackItem(i) ? i.pack_size : null };
}

/** Parse a typed whole count (1–100,000); null = not a valid count. */
export function parseCount(text: string, max = 100_000): number | null {
  const s = text.replace(/[\s,.]/g, '');
  if (!/^\d+$/.test(s)) return null;
  const n = Number(s);
  return n >= 1 && n <= max ? n : null;
}

/** Amount wording, as an i18n key + values (for "73 packs + 40 = 7,340"). */
export function amountKey(
  packs: number,
  loose: number,
  pieces: number,
): { key: string; values: { packs: number; loose: number; pieces: number; count: number } } {
  const values = { packs, loose, pieces, count: packs };
  if (packs > 0 && loose > 0) return { key: 'finished.amount.packsLoose', values };
  if (packs > 0) return { key: 'finished.amount.packs', values };
  return { key: 'finished.amount.pieces', values: { ...values, count: pieces } };
}

// ── Double-tap guard ──────────────────────────────────────────────────────

export const DOUBLE_TAP_MS = 5_000;

export interface LastAdd {
  itemId: string;
  pieces: number;
  at: number;
}

/** The same item and the same amount again within ~5 s: ask "Add another 500?" instead of saving. */
export function isDoubleTap(
  last: LastAdd | null,
  itemId: string,
  pieces: number,
  nowMs: number,
  windowMs: number = DOUBLE_TAP_MS,
): boolean {
  return (
    !!last &&
    last.itemId === itemId &&
    last.pieces === pieces &&
    nowMs - last.at >= 0 &&
    nowMs - last.at < windowMs
  );
}

// ── Big-number check ──────────────────────────────────────────────────────

/** A single entry above this many pieces asks for confirmation. */
export const SINGLE_ENTRY_CONFIRM = 5_000;

export type BigWarning = { kind: 'stock' } | { kind: 'single'; pieces: number };

/**
 * Confirmations needed before saving: this shift's total after the add would exceed the stock the plant
 * owns, and/or the single entry is more than 5,000 pieces. Empty = save straight away.
 *
 * Stock owned is owner-only (owner 2026-11-10): the client never sees the number. `overStock` is the
 * answer of the finished_goods_over_stock RPC; null = unknown (offline, failed, no stock set), and the
 * stock check is then skipped, never blocking the save. The 5,000 check is always client-side.
 */
export function bigNumberWarnings(pieces: number, overStock: boolean | null): BigWarning[] {
  const out: BigWarning[] = [];
  if (overStock === true) out.push({ kind: 'stock' });
  if (pieces > SINGLE_ENTRY_CONFIRM) out.push({ kind: 'single', pieces });
  return out;
}

// ── Pace and the end-of-shift review ──────────────────────────────────────

/** Below this span between the first and last line, a pace would be noise: none is shown. */
export const MIN_PACE_SPAN_MS = 15 * 60_000;

/** Pieces per hour between the first and last line of an item (per item per shift, never per person). */
export function pacePerHour(
  timesIso: readonly string[],
  pieces: number,
  minSpanMs: number = MIN_PACE_SPAN_MS,
): number | null {
  const ts = timesIso.map((s) => Date.parse(s)).filter((n) => !Number.isNaN(n));
  if (ts.length < 2) return null;
  const span = Math.max(...ts) - Math.min(...ts);
  if (span < minSpanMs) return null;
  return Math.round(pieces / (span / 3_600_000));
}

/** One line on the screen: a server entry, or one still on this device. */
export interface LogLine {
  key: string;
  itemTypeId: string;
  packs: number;
  loose: number;
  pieces: number;
  occurredAt: string;
  /** Server id; null while the line is only on this device. */
  id: string | null;
  clientId: string;
  /** Not sent yet (saved on the tablet). */
  pending: boolean;
}

export interface ReviewRow {
  itemTypeId: string;
  packs: number;
  loose: number;
  pieces: number;
  lines: number;
  first: string;
  last: string;
  pace: number | null;
}

/** Per-item totals for the review, in the given item order (items with no line are left out). */
export function buildReview(lines: readonly LogLine[], itemOrder: readonly string[]): ReviewRow[] {
  const by = new Map<string, LogLine[]>();
  for (const l of lines) {
    const list = by.get(l.itemTypeId) ?? [];
    list.push(l);
    by.set(l.itemTypeId, list);
  }
  const order = [...itemOrder, ...[...by.keys()].filter((k) => !itemOrder.includes(k))];
  const rows: ReviewRow[] = [];
  for (const id of order) {
    const list = by.get(id);
    if (!list || list.length === 0) continue;
    const times = list.map((l) => l.occurredAt).sort((a, b) => Date.parse(a) - Date.parse(b));
    const pieces = list.reduce((n, l) => n + l.pieces, 0);
    rows.push({
      itemTypeId: id,
      packs: list.reduce((n, l) => n + l.packs, 0),
      loose: list.reduce((n, l) => n + l.loose, 0),
      pieces,
      lines: list.length,
      first: times[0] as string,
      last: times[times.length - 1] as string,
      pace: pacePerHour(times, pieces),
    });
  }
  return rows;
}

/** Total pieces of one item over these lines. */
export function itemTotal(lines: readonly LogLine[], itemTypeId: string): number {
  return lines.reduce((n, l) => (l.itemTypeId === itemTypeId ? n + l.pieces : n), 0);
}

// ── "Working on" list, per user per device ────────────────────────────────

export const WORKING_KEY = 'finished.working.v1';
export const MAX_WORKING = 6;

export interface WorkingPrefs {
  items: string[];
  selected: string | null;
}

/** Saved prefs made safe: unknown items dropped, no duplicates, at most 6, selected one of them. */
export function normalizeWorking(saved: unknown, validIds?: ReadonlySet<string>): WorkingPrefs {
  const o = saved && typeof saved === 'object' ? (saved as Record<string, unknown>) : {};
  const raw = Array.isArray(o.items) ? o.items : [];
  const items: string[] = [];
  for (const x of raw) {
    if (typeof x !== 'string' || items.includes(x)) continue;
    if (validIds && !validIds.has(x)) continue;
    items.push(x);
  }
  const kept = items.slice(-MAX_WORKING);
  const sel = typeof o.selected === 'string' && kept.includes(o.selected) ? o.selected : null;
  return { items: kept, selected: sel ?? kept[0] ?? null };
}

/** Pin an item (selected). A 7th item drops the oldest pin that is not the new one. */
export function addWorking(p: WorkingPrefs, id: string): WorkingPrefs {
  const items = p.items.includes(id) ? p.items : [...p.items, id];
  return { items: items.slice(-MAX_WORKING), selected: id };
}

export function removeWorking(p: WorkingPrefs, id: string): WorkingPrefs {
  const items = p.items.filter((x) => x !== id);
  return { items, selected: p.selected === id ? (items[0] ?? null) : p.selected };
}

function readJson(store: KeyValueStore, key: string): unknown {
  try {
    const raw = store.getItem(key);
    return raw ? (JSON.parse(raw) as unknown) : null;
  } catch {
    return null;
  }
}

function writeJson(store: KeyValueStore, key: string, value: unknown): void {
  try {
    store.setItem(key, JSON.stringify(value));
  } catch {
    /* the device refused: the list just isn't remembered */
  }
}

export function loadWorking(store: KeyValueStore): WorkingPrefs {
  return normalizeWorking(readJson(store, WORKING_KEY));
}

export function saveWorking(store: KeyValueStore, p: WorkingPrefs): void {
  writeJson(store, WORKING_KEY, { items: p.items, selected: p.selected });
}

// ── "Sheets done…" count (Sheet – old) ────────────────────────────────────
// Owner 2026-11-10: old sheets go into ONE fixed bin they keep adding to, so there is no "bin done";
// the manager types how many old sheets were finished (usually ~500). The last count used for the item
// on this device pre-fills the next one. (The storage key keeps its old name so a device keeps its
// last count.)

export const SHEETS_COUNT_KEY = 'finished.binCount.v1';

export function loadSheetsCount(store: KeyValueStore, itemId: string): number | null {
  const o = readJson(store, SHEETS_COUNT_KEY);
  if (!o || typeof o !== 'object') return null;
  const v = (o as Record<string, unknown>)[itemId];
  return typeof v === 'number' && Number.isInteger(v) && v > 0 ? v : null;
}

export function saveSheetsCount(store: KeyValueStore, itemId: string, count: number): void {
  const o = readJson(store, SHEETS_COUNT_KEY);
  const map = o && typeof o === 'object' ? { ...(o as Record<string, unknown>) } : {};
  map[itemId] = count;
  writeJson(store, SHEETS_COUNT_KEY, map);
}

/**
 * "Sheets done…" (one count of pieces, no packs, no "Leftover…") applies to sheet pack items with no
 * bin size: Sheet – old.
 */
export function isSheetsDoneItem(i: FinishItem): boolean {
  return i.bin_size === null && finishGroupOf(i) === 'sheets' && isPackItem(i);
}
