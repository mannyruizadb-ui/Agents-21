// Pure helpers for Setup → Items (owner 2026-11-10). They mirror the item_types CHECKs so the owner
// gets a clear message before saving; the database stays the final validator.
import { parseDecimal } from './setupForm';

export interface ItemNumbers {
  count_mode: 'pack' | 'unit';
  pack_size: number | null;
  bin_size: number | null;
  stock_qty: number | null;
  pieces_per_load: number | null;
  pieces_per_load_source: string | null;
  color_hex: string;
  active: boolean;
}

export interface ItemDraft {
  packSize: string;
  binSize: string;
  stock: string;
  perLoad: string;
  perLoadSource: 'counted' | 'derived';
  color: string;
  active: boolean;
}

/** A few fabric colours to pick with one tap (white, black, bone, navy, red, green, chambray, pink). */
export const PRESET_COLORS = [
  '#FFFFFF',
  '#000000',
  '#E7DCC4',
  '#1E3A8A',
  '#DC2626',
  '#15803D',
  '#8FA9C8',
  '#EC4899',
] as const;

/** Whole number in [min, max]; blank = null. */
export function parseWhole(input: string, min: number, max: number): number | null | 'invalid' {
  const s = input.trim().replace(/[\s,]/g, '');
  if (s === '') return null;
  if (!/^\d{1,8}$/.test(s)) return 'invalid';
  const n = Number(s);
  return n >= min && n <= max ? n : 'invalid';
}

/** Draft → the changed columns, or a message key. */
export function itemPatch(
  item: ItemNumbers,
  d: ItemDraft,
): Partial<Omit<ItemNumbers, 'count_mode'>> | string {
  const packSize = parseWhole(d.packSize, 1, 10_000);
  if (packSize === 'invalid') return 'setup.items.errors.packSize';
  if (item.count_mode === 'pack' && packSize === null) return 'setup.items.errors.packSize';
  const binSize = parseWhole(d.binSize, 1, 5_000);
  if (binSize === 'invalid') return 'setup.items.errors.binSize';
  const stock = parseWhole(d.stock, 0, 10_000_000);
  if (stock === 'invalid') return 'setup.items.errors.stock';
  const perLoad = parseDecimal(d.perLoad, 9999, 2);
  if (perLoad === 'invalid') return 'setup.items.errors.perLoad';
  if (!/^#[0-9A-Fa-f]{6}$/.test(d.color)) return 'setup.errors.invalid';

  const patch: Partial<Omit<ItemNumbers, 'count_mode'>> = {};
  if (item.count_mode === 'pack' && packSize !== item.pack_size) patch.pack_size = packSize;
  if (binSize !== item.bin_size) patch.bin_size = binSize;
  if (stock !== item.stock_qty) patch.stock_qty = stock;
  const source = perLoad === null ? null : d.perLoadSource;
  if (perLoad !== item.pieces_per_load || source !== item.pieces_per_load_source) {
    // The DB requires both or neither (item_types CHECK).
    patch.pieces_per_load = perLoad;
    patch.pieces_per_load_source = source;
  }
  const color = d.color.toUpperCase();
  if (color !== item.color_hex.toUpperCase()) patch.color_hex = color;
  if (d.active !== item.active) patch.active = d.active;
  return patch;
}
