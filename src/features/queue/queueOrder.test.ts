import { describe, expect, it } from 'vitest';
import { applyMove, canMove, moveAfterId, parseLoads, placeNumbers } from './queueOrder';

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
