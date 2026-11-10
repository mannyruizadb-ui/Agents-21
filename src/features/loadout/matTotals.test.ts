import { describe, expect, it } from 'vitest';
import { compareSizes, matIndex, matPieces, matSections, matSize, matTotals } from './matTotals';

const g = (id: string, sort_order: number) => ({ id, name: id, sort_order });
const item = (
  id: string,
  name: string,
  group: string | null,
  sort_order = 0,
  extra: Partial<{ count_mode: string; pack_size: number | null; active: boolean }> = {},
) => ({
  id,
  name,
  wash_group_id: group,
  count_mode: 'unit',
  pack_size: null,
  sort_order,
  active: true,
  ...extra,
});

describe('matSize', () => {
  it('reads the size at the end of the name', () => {
    expect(matSize('Black mat 3×5')).toBe('3×5');
    expect(matSize('Black City mat 3×10')).toBe('3×10');
    expect(matSize('Colored mat 2x3')).toBe('2×3');
    expect(matSize('Red Brito mat 4 X 6 ')).toBe('4×6');
  });
  it('null without a size', () => {
    expect(matSize('Mop head')).toBeNull();
  });
});

describe('compareSizes', () => {
  it("follows the owner's order, then other sizes by area, then no size", () => {
    const sizes = ['5×7', null, '4×8', '3×10', '2×3', '4×6', '3×5', '2×2'];
    expect([...sizes].sort(compareSizes)).toEqual([
      '2×3',
      '3×5',
      '4×6',
      '3×10',
      '5×7',
      '2×2',
      '4×8',
      null,
    ]);
  });
});

describe('matSections', () => {
  const groups = [g('colored', 2), g('black', 1), g('empty', 3)];
  const items = [
    item('b57', 'Black mat 5×7', 'black', 50),
    item('b35', 'Black mat 3×5', 'black', 20),
    item('city35', 'Black City mat 3×5', 'black', 116),
    item('b23', 'Black mat 2×3', 'black', 10),
    item('c46', 'Colored mat 4×6', 'colored', 80),
    item('old', 'Colored mat 3×5', 'colored', 70, { active: false }),
    item('sheet', 'Sheet', null),
  ];
  it('groups by colour in group order, sizes in owner order, only existing active items', () => {
    const s = matSections(groups, items);
    expect(s.map((x) => x.group.id)).toEqual(['black', 'colored']);
    expect(s[0]?.items.map((x) => x.item.id)).toEqual(['b23', 'b35', 'city35', 'b57']);
    expect(s[1]?.items.map((x) => x.item.id)).toEqual(['c46']);
  });
  it('indexes items by id with size and group', () => {
    const idx = matIndex(matSections(groups, items));
    expect(idx.get('city35')).toMatchObject({ size: '3×5', groupId: 'black' });
    expect(idx.has('sheet')).toBe(false);
    expect(idx.has('old')).toBe(false);
  });
});

describe('matPieces', () => {
  it('unit items count as pieces', () => {
    expect(matPieces({ count_mode: 'unit', pack_size: null }, 7)).toBe(7);
  });
  it('pack items are typed in pieces too (owner 2026-11-10): never multiplied', () => {
    expect(matPieces({ count_mode: 'pack', pack_size: 5 }, 30)).toBe(30);
    expect(matPieces({ count_mode: 'pack', pack_size: null }, 3)).toBe(3);
  });
});

describe('matTotals', () => {
  it('adds up by size (across colours) and overall, in size order', () => {
    const t = matTotals([
      { size: '3×5', pieces: 12 },
      { size: '2×3', pieces: 4 },
      { size: '3×5', pieces: 3 },
      { size: '5×7', pieces: 0 },
      { size: '3×10', pieces: 2 },
    ]);
    expect(t.bySize).toEqual([
      { size: '2×3', pieces: 4 },
      { size: '3×5', pieces: 15 },
      { size: '3×10', pieces: 2 },
    ]);
    expect(t.total).toBe(21);
    expect(t.unknown).toBe(0);
  });
  it('leaves unknown pieces out of the total and counts them', () => {
    const t = matTotals([
      { size: '4×6', pieces: null },
      { size: '4×6', pieces: 5 },
    ]);
    expect(t.total).toBe(5);
    expect(t.unknown).toBe(1);
  });
  it('is empty with nothing typed', () => {
    expect(matTotals([])).toEqual({ bySize: [], total: 0, unknown: 0 });
  });
});
