import { describe, expect, it } from 'vitest';
import { memoryStore, scopedKey, scopedStore } from '../../lib/scopedStore';
import {
  chipCounts,
  chipsFor,
  effectiveChip,
  inChip,
  loadChip,
  narrowCategory,
  saveChip,
  type Category,
} from './categories';

const cats = new Map<string, Category>([
  ['n1', 'napkins'],
  ['n2', 'napkins'],
  ['m1', 'mats'],
  ['o1', 'other'],
]);

describe('category chips', () => {
  it('narrows unknown values to other', () => {
    expect(narrowCategory('sheets')).toBe('sheets');
    expect(narrowCategory('linen')).toBe('other');
    expect(narrowCategory(null)).toBe('other');
  });

  it('shows only chips that have groups, in order, and none without categories', () => {
    expect(chipsFor(['m1', 'n1', 'o1'], cats)).toEqual(['all', 'napkins', 'mats', 'other']);
    expect(chipsFor(['m1', 'n1'], cats)).toEqual(['all', 'napkins', 'mats']);
    expect(chipsFor(['m1'], new Map())).toEqual([]);
  });

  it('filters and counts groups with work', () => {
    expect(inChip('n1', 'napkins', cats)).toBe(true);
    expect(inChip('o1', 'napkins', cats)).toBe(false);
    expect(inChip('o1', 'all', cats)).toBe(true);
    const c = chipCounts(['n1', 'n2', 'm1', 'o1'], cats, (id) => id !== 'n2');
    expect(c.get('all')).toBe(3);
    expect(c.get('napkins')).toBe(1);
    expect(c.get('mats')).toBe(1);
    expect(c.get('sheets')).toBeUndefined();
  });

  it('falls back to All when the saved chip is not on screen', () => {
    expect(effectiveChip('sheets', ['all', 'napkins'])).toBe('all');
    expect(effectiveChip('napkins', ['all', 'napkins'])).toBe('napkins');
  });

  it('remembers the chip per user and survives bad or throwing storage', () => {
    const base = memoryStore();
    const a = scopedStore(base, 'user-a');
    saveChip(a, 'mats');
    expect(base.getItem(scopedKey('user-a', 'estimates.chip.v1'))).toBe('mats');
    expect(loadChip(a)).toBe('mats');
    expect(loadChip(scopedStore(base, 'user-b'))).toBe('all');
    base.setItem(scopedKey('user-a', 'estimates.chip.v1'), 'bogus');
    expect(loadChip(a)).toBe('all');
    const broken = {
      getItem: () => {
        throw new Error('denied');
      },
      setItem: () => {
        throw new Error('denied');
      },
    };
    expect(loadChip(broken)).toBe('all');
    expect(() => saveChip(broken, 'mats')).not.toThrow();
  });
});
