import { describe, expect, it } from 'vitest';
import { itemPatch, parseWhole, type ItemDraft, type ItemNumbers } from './setupItemsForm';

const item: ItemNumbers = {
  count_mode: 'pack',
  pack_size: 10,
  bin_size: null,
  stock_qty: null,
  pieces_per_load: null,
  pieces_per_load_source: null,
  color_hex: '#FFFFFF',
  active: true,
};
const draft = (over: Partial<ItemDraft> = {}): ItemDraft => ({
  packSize: '10',
  binSize: '',
  stock: '',
  perLoad: '',
  perLoadSource: 'counted',
  color: '#ffffff',
  active: true,
  ...over,
});

describe('Setup → Items form', () => {
  it('parses whole numbers in range', () => {
    expect(parseWhole('', 1, 5)).toBeNull();
    expect(parseWhole('10,000', 0, 10_000)).toBe(10_000);
    expect(parseWhole('0', 1, 5)).toBe('invalid');
    expect(parseWhole('2.5', 1, 5)).toBe('invalid');
  });
  it('sends only what changed', () => {
    expect(itemPatch(item, draft())).toEqual({});
    expect(itemPatch(item, draft({ binSize: '500', stock: '10000', color: '#000000' }))).toEqual({
      bin_size: 500,
      stock_qty: 10_000,
      color_hex: '#000000',
    });
  });
  it('pieces per load goes with its source (both or neither)', () => {
    expect(itemPatch(item, draft({ perLoad: '120', perLoadSource: 'derived' }))).toEqual({
      pieces_per_load: 120,
      pieces_per_load_source: 'derived',
    });
    expect(
      itemPatch(
        { ...item, pieces_per_load: 120, pieces_per_load_source: 'counted' },
        draft({ perLoad: '' }),
      ),
    ).toEqual({ pieces_per_load: null, pieces_per_load_source: null });
  });
  it('mirrors the CHECKs', () => {
    expect(itemPatch(item, draft({ packSize: '' }))).toBe('setup.items.errors.packSize');
    expect(itemPatch(item, draft({ binSize: '6000' }))).toBe('setup.items.errors.binSize');
    expect(itemPatch(item, draft({ stock: '-1' }))).toBe('setup.items.errors.stock');
    expect(itemPatch(item, draft({ perLoad: '0' }))).toBe('setup.items.errors.perLoad');
  });
});
