// Mats on the load-out (owner 2026-11-09: "by all 3": colour, size and totals). The owner types mats per
// route by colour (the active mat basket groups: Black, Colored, Charcoal, Brito) and size; the screen
// adds them up by size and overall, per route and for the day. Mats are counted in pieces (their
// item_types are count_mode 'unit'). Only items that exist are shown. Pure module, for tests.

/** The owner's size order; any other size goes after these, smaller first. */
export const MAT_SIZE_ORDER = ['2×3', '3×5', '4×6', '3×10', '5×7'] as const;

const SIZE_RE = /(\d+)\s*[×xX]\s*(\d+)\s*$/;

/** "Black mat 3×5" → "3×5" ("3x5" and "3 X 5" read the same); null when the name has no size. */
export function matSize(name: string): string | null {
  const m = SIZE_RE.exec(name.trim());
  return m ? `${Number(m[1])}×${Number(m[2])}` : null;
}

function sizeRank(size: string | null): [number, number] {
  if (size === null) return [2, 0];
  const i = (MAT_SIZE_ORDER as readonly string[]).indexOf(size);
  if (i >= 0) return [0, i];
  const [a = 0, b = 0] = size.split('×').map(Number);
  return [1, a * b];
}

/** Sort order for sizes: the owner's order, then other sizes by area, then "no size". */
export function compareSizes(a: string | null, b: string | null): number {
  const [ka, va] = sizeRank(a);
  const [kb, vb] = sizeRank(b);
  return ka - kb || va - vb || (a ?? '').localeCompare(b ?? '');
}

export interface MatGroupLike {
  id: string;
  name: string;
  sort_order: number;
}

export interface MatItemLike {
  id: string;
  name: string;
  wash_group_id: string | null;
  count_mode: string;
  pack_size: number | null;
  sort_order: number;
  active: boolean;
}

export interface MatSection<G, I> {
  group: G;
  items: { item: I; size: string | null }[];
}

/**
 * One section per colour (mat group) that has active items, in the groups' order; inside, items by
 * size (owner order), then their own order. Items outside the given groups are left out.
 */
export function matSections<G extends MatGroupLike, I extends MatItemLike>(
  groups: readonly G[],
  items: readonly I[],
): MatSection<G, I>[] {
  return [...groups]
    .sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name))
    .map((group) => ({
      group,
      items: items
        .filter((i) => i.active && i.wash_group_id === group.id)
        .map((item) => ({ item, size: matSize(item.name) }))
        .sort(
          (a, b) =>
            compareSizes(a.size, b.size) ||
            a.item.sort_order - b.item.sort_order ||
            a.item.name.localeCompare(b.item.name),
        ),
    }))
    .filter((s) => s.items.length > 0);
}

/**
 * Pieces for a quantity of a mat item. Owner 2026-11-10: every load-out quantity is typed in pieces
 * (from the invoice), pack items included, so it is the quantity itself. Kept as one function so the
 * rule lives in one place.
 */
export function matPieces(
  _item: Pick<MatItemLike, 'count_mode' | 'pack_size'>,
  qty: number,
): number | null {
  return qty;
}

export interface SizeTotal {
  /** null = a mat item whose name has no size */
  size: string | null;
  pieces: number;
}

export interface MatTotals {
  /** Sizes with pieces, in size order. */
  bySize: SizeTotal[];
  total: number;
  /** Lines left out because their pieces are unknown (pack item without a pack size). */
  unknown: number;
}

/** Adds mat lines up by size and overall. */
export function matTotals(
  lines: readonly { size: string | null; pieces: number | null }[],
): MatTotals {
  const by = new Map<string | null, number>();
  let total = 0;
  let unknown = 0;
  for (const l of lines) {
    if (l.pieces === null) {
      unknown += 1;
      continue;
    }
    if (l.pieces <= 0) continue;
    by.set(l.size, (by.get(l.size) ?? 0) + l.pieces);
    total += l.pieces;
  }
  const bySize = [...by.entries()]
    .map(([size, pieces]) => ({ size, pieces }))
    .sort((a, b) => compareSizes(a.size, b.size));
  return { bySize, total, unknown };
}

/** Mat item id → its size and group, for reading board lines. */
export function matIndex<I extends MatItemLike>(
  sections: readonly MatSection<MatGroupLike, I>[],
): Map<string, { item: I; size: string | null; groupId: string }> {
  const m = new Map<string, { item: I; size: string | null; groupId: string }>();
  for (const s of sections)
    for (const x of s.items) m.set(x.item.id, { item: x.item, size: x.size, groupId: s.group.id });
  return m;
}
