import type { KeyValueStore } from '../../lib/scopedStore';

// Wash group categories for the filter chips on the estimates screen and the AA delivery entry
// (owner 2026-11-09: "no long scroll"). The value comes from wash_groups.category; anything missing or
// unknown counts as 'other' (shown under All, plus an Other chip only when such groups exist).
// Pure except load/save through the given store.

export const CATEGORIES = [
  'napkins',
  'tablecloths',
  'sheets',
  'mats',
  'towels_aprons',
  'mops',
  'other',
] as const;
export type Category = (typeof CATEGORIES)[number];
export type Chip = 'all' | Category;

export const CHIP_KEY = 'estimates.chip.v1';

export function narrowCategory(raw: unknown): Category {
  return typeof raw === 'string' && (CATEGORIES as readonly string[]).includes(raw)
    ? (raw as Category)
    : 'other';
}

/**
 * The chips to show for these groups, in the fixed order, "all" first. Empty when no category is
 * known at all (the column isn't there yet or failed to load): then no chip row is drawn.
 */
export function chipsFor(
  ids: readonly string[],
  categoryOf: ReadonlyMap<string, Category>,
): Chip[] {
  if (categoryOf.size === 0 || ids.length === 0) return [];
  const present = new Set(ids.map((id) => categoryOf.get(id) ?? 'other'));
  return ['all', ...CATEGORIES.filter((c) => present.has(c))];
}

export function inChip(id: string, chip: Chip, categoryOf: ReadonlyMap<string, Category>): boolean {
  return chip === 'all' || (categoryOf.get(id) ?? 'other') === chip;
}

/** How many of `ids` fall under each chip and satisfy `counts` (e.g. "has work waiting"). */
export function chipCounts(
  ids: readonly string[],
  categoryOf: ReadonlyMap<string, Category>,
  counts: (id: string) => boolean,
): Map<Chip, number> {
  const out = new Map<Chip, number>([['all', 0]]);
  for (const id of ids) {
    if (!counts(id)) continue;
    const c = categoryOf.get(id) ?? 'other';
    out.set('all', (out.get('all') ?? 0) + 1);
    out.set(c, (out.get(c) ?? 0) + 1);
  }
  return out;
}

/** The chip to use: the saved one when it is still on screen, else All. */
export function effectiveChip(chosen: Chip, chips: readonly Chip[]): Chip {
  return chips.includes(chosen) ? chosen : 'all';
}

export function loadChip(store: KeyValueStore): Chip {
  try {
    const raw = store.getItem(CHIP_KEY);
    return raw === 'all'
      ? 'all'
      : raw && (CATEGORIES as readonly string[]).includes(raw)
        ? (raw as Category)
        : 'all';
  } catch {
    return 'all';
  }
}

export function saveChip(store: KeyValueStore, chip: Chip): void {
  try {
    store.setItem(CHIP_KEY, chip);
  } catch {
    // Storage refused (private mode, full): the choice just isn't remembered.
  }
}
