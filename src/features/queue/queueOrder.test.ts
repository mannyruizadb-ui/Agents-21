import { describe, expect, it } from 'vitest';
import {
  addedByToShow,
  applyMove,
  arrayMove,
  canMove,
  dropAfterId,
  moveAfterId,
  nextUnassigned,
  parseLoads,
  placeAfterId,
  placeNumbers,
  placeRange,
  samePartition,
  topAfterId,
} from './queueOrder';

// Board order: rush r1, r2, then normal a, b, c.
const items = [
  { id: 'r1', is_rush: true },
  { id: 'r2', is_rush: true },
  { id: 'a', is_rush: false },
  { id: 'b', is_rush: false },
  { id: 'c', is_rush: false },
];
const ids = (list: { id: string }[]) => list.map((i) => i.id);

describe('moveAfterId', () => {
  it('moving up puts the item below the one two places up, or at the top', () => {
    expect(moveAfterId(items, 'c', 'up')).toBe('a');
    expect(moveAfterId(items, 'b', 'up')).toBeNull();
    expect(moveAfterId(items, 'r2', 'up')).toBeNull();
  });
  it('moving down puts the item below the next one', () => {
    expect(moveAfterId(items, 'a', 'down')).toBe('b');
    expect(moveAfterId(items, 'r1', 'down')).toBe('r2');
  });
  it('never crosses the RUSH / normal boundary', () => {
    expect(moveAfterId(items, 'a', 'up')).toBeUndefined();
    expect(moveAfterId(items, 'r2', 'down')).toBeUndefined();
    expect(canMove(items, 'c', 'down')).toBe(false);
    expect(canMove(items, 'r1', 'up')).toBe(false);
    expect(moveAfterId(items, 'zzz', 'up')).toBeUndefined();
  });
});

describe('applyMove', () => {
  it('matches the server rule for each button', () => {
    expect(ids(applyMove(items, 'c', moveAfterId(items, 'c', 'up') ?? null))).toEqual([
      'r1',
      'r2',
      'a',
      'c',
      'b',
    ]);
    expect(ids(applyMove(items, 'b', null))).toEqual(['r1', 'r2', 'b', 'a', 'c']);
    expect(ids(applyMove(items, 'r1', 'r2'))).toEqual(['r2', 'r1', 'a', 'b', 'c']);
    expect(ids(applyMove(items, 'a', 'b'))).toEqual(['r1', 'r2', 'b', 'a', 'c']);
  });
  it('handles a partition that is otherwise empty', () => {
    const one = [{ id: 'x', is_rush: false }];
    expect(ids(applyMove(one, 'x', null))).toEqual(['x']);
  });
  it('leaves the list alone for unknown ids', () => {
    expect(ids(applyMove(items, 'nope', null))).toEqual(ids(items));
    expect(ids(applyMove(items, 'a', 'nope'))).toEqual(ids(items));
  });
  it('numbers places from 1', () => {
    expect(placeNumbers(items).get('a')).toBe(3);
  });
});

describe('parseLoads', () => {
  it('accepts 0.01–100000 with up to 2 decimals, comma or dot', () => {
    expect(parseLoads('2')).toBe(2);
    expect(parseLoads(' 1.5 ')).toBe(1.5);
    expect(parseLoads('1,25')).toBe(1.25);
    expect(parseLoads('100000')).toBe(100000);
  });
  it('rejects empty, zero, negatives, too many decimals and too big', () => {
    for (const bad of ['', '0', '-1', '1.234', '100000.01', 'abc', '1e3']) {
      expect(parseLoads(bad)).toBeNull();
    }
  });
});

describe('nextUnassigned', () => {
  const q = [
    { id: 'r1', is_rush: true, assigned_machine_id: null },
    { id: 'p', is_rush: true, assigned_machine_id: 'w2' },
    { id: 'a', is_rush: false, assigned_machine_id: null },
    { id: 'b', is_rush: false, assigned_machine_id: null },
  ];
  it('lists unassigned items once, in board order, with a count of the rest', () => {
    const r = nextUnassigned(q, 2);
    expect(ids(r.shown)).toEqual(['r1', 'a']);
    expect(r.more).toBe(1);
    expect(nextUnassigned(q, 5).more).toBe(0);
    expect(nextUnassigned([], 3)).toEqual({ shown: [], more: 0 });
  });
});

describe('dropAfterId (drag and drop)', () => {
  it('dropping on a later item puts it below that item', () => {
    expect(dropAfterId(items, 'a', 'c')).toBe('c');
    expect(dropAfterId(items, 'a', 'b')).toBe('b');
    expect(dropAfterId(items, 'r1', 'r2')).toBe('r2');
  });
  it('dropping on an earlier item puts it above that item (below the one before it)', () => {
    expect(dropAfterId(items, 'c', 'b')).toBe('a');
    expect(dropAfterId(items, 'r2', 'r1')).toBeNull();
  });
  it('the top of the normal items is p_after_id null (never after a RUSH item)', () => {
    expect(dropAfterId(items, 'c', 'a')).toBeNull();
    expect(dropAfterId(items, 'b', 'a')).toBeNull();
  });
  it('refuses a drop across the RUSH boundary, like the server', () => {
    expect(dropAfterId(items, 'a', 'r2')).toBeUndefined();
    expect(dropAfterId(items, 'c', 'r1')).toBeUndefined();
    expect(dropAfterId(items, 'r2', 'a')).toBeUndefined();
    expect(samePartition(items, 'a', 'r2')).toBe(false);
    expect(samePartition(items, 'a', 'c')).toBe(true);
  });
  it('no move for a drop on itself, nowhere, or unknown ids', () => {
    expect(dropAfterId(items, 'a', 'a')).toBeUndefined();
    expect(dropAfterId(items, 'a', null)).toBeUndefined();
    expect(dropAfterId(items, 'zzz', 'a')).toBeUndefined();
    expect(dropAfterId(items, 'a', 'zzz')).toBeUndefined();
  });
  it('the optimistic list matches the drop for every pair in a partition', () => {
    for (const from of ['a', 'b', 'c'])
      for (const to of ['a', 'b', 'c']) {
        if (from === to) continue;
        const after = dropAfterId(items, from, to);
        expect(after).not.toBeUndefined();
        const fi = items.findIndex((i) => i.id === from);
        const ti = items.findIndex((i) => i.id === to);
        expect(ids(applyMove(items, from, after ?? null))).toEqual(ids(arrayMove(items, fi, ti)));
      }
  });
});

describe('Move to top / Move to position', () => {
  it('Move to top goes to the top of the partition; nothing when already first', () => {
    expect(topAfterId(items, 'c')).toBeNull();
    expect(topAfterId(items, 'a')).toBeUndefined();
    expect(topAfterId(items, 'r2')).toBeNull();
    expect(topAfterId(items, 'r1')).toBeUndefined();
    expect(topAfterId(items, 'zzz')).toBeUndefined();
  });
  it('knows the places each partition can use', () => {
    expect(placeRange(items, 'b')).toEqual({ first: 3, last: 5 });
    expect(placeRange(items, 'r1')).toEqual({ first: 1, last: 2 });
    expect(placeRange(items, 'zzz')).toBeNull();
  });
  it('moves to a board place inside the partition', () => {
    expect(placeAfterId(items, 'c', 3)).toBeNull();
    expect(placeAfterId(items, 'c', 4)).toBe('a');
    expect(placeAfterId(items, 'a', 5)).toBe('c');
    expect(placeAfterId(items, 'a', 4)).toBe('b');
    expect(placeAfterId(items, 'r1', 2)).toBe('r2');
  });
  it('clamps to the partition: a normal item never goes above RUSH items', () => {
    expect(placeAfterId(items, 'c', 1)).toBeNull();
    expect(placeAfterId(items, 'r1', 9)).toBe('r2');
    expect(placeAfterId(items, 'b', 99)).toBe('c');
  });
  it('nothing to do when already there, or for bad input', () => {
    expect(placeAfterId(items, 'a', 3)).toBeUndefined();
    expect(placeAfterId(items, 'a', 1)).toBeUndefined();
    expect(placeAfterId(items, 'a', 2.5)).toBeUndefined();
    expect(placeAfterId(items, 'zzz', 1)).toBeUndefined();
  });
});

describe('addedByToShow', () => {
  it("hides the viewer's own name, shows anyone else", () => {
    expect(addedByToShow('Owner Name', 'Owner Name')).toBeNull();
    expect(addedByToShow(' owner name ', 'Owner Name')).toBeNull();
    expect(addedByToShow('Denise', 'Owner Name')).toBe('Denise');
    expect(addedByToShow('Denise', null)).toBe('Denise');
    expect(addedByToShow(null, 'Owner Name')).toBeNull();
    expect(addedByToShow('  ', 'Owner Name')).toBeNull();
  });
});
