import { describe, expect, it } from 'vitest';
import { memoryStore, scopedKey, scopedStore } from '../../lib/scopedStore';
import {
  defaultOrder,
  loadPrefs,
  moveTile,
  normalizePrefs,
  savePrefs,
  toggleTile,
  visibleTiles,
} from './homePrefs';

describe('home prefs', () => {
  it('defaults by role', () => {
    expect(visibleTiles(normalizePrefs(null, 'owner'))).toEqual(defaultOrder('owner'));
    expect(visibleTiles(normalizePrefs(null, 'other'))).toEqual(['washers', 'queue', 'nextTruck']);
  });

  it('keeps the owner to the tiles the dashboard does not already show, and drops old alerts tiles', () => {
    const p = normalizePrefs(
      { order: ['washers', 'alerts', 'queue', 'dirtyWork'], hidden: ['alerts'] },
      'owner',
    );
    expect(p.order).toEqual(['queue', 'machinesDown', 'nextTruck', 'tasks']);
    expect(p.hidden).toEqual([]);
    expect(normalizePrefs(null, 'manager').order).not.toContain('alerts');
  });

  it('drops unknown and not-allowed tiles and appends missing allowed ones', () => {
    const p = normalizePrefs(
      { order: ['queue', 'bogus', 'tasks', 'queue'], hidden: ['washers', 'alerts', 7] },
      'other',
    );
    expect(p.order).toEqual(['queue', 'washers', 'nextTruck']);
    expect(p.hidden).toEqual(['washers']);
  });

  it('toggles and moves', () => {
    let p = normalizePrefs(null, 'other');
    p = toggleTile(p, 'queue');
    expect(visibleTiles(p)).toEqual(['washers', 'nextTruck']);
    p = toggleTile(p, 'queue');
    p = moveTile(p, 'nextTruck', -1);
    expect(p.order).toEqual(['washers', 'nextTruck', 'queue']);
    expect(moveTile(p, 'washers', -1)).toBe(p);
    expect(moveTile(p, 'queue', 1)).toBe(p);
  });

  it('saves per user under plantboard.<userId>.home.v1 and survives bad JSON', () => {
    const base = memoryStore();
    const a = scopedStore(base, 'user-a');
    const p = moveTile(normalizePrefs(null, 'owner'), 'queue', -1);
    savePrefs(a, p);
    expect(base.getItem(scopedKey('user-a', 'home.v1'))).toContain('"queue"');
    expect(loadPrefs(a, 'owner')).toEqual(p);
    expect(loadPrefs(scopedStore(base, 'user-b'), 'owner').order).toEqual(defaultOrder('owner'));
    base.setItem(scopedKey('user-a', 'home.v1'), '{nope');
    expect(loadPrefs(a, 'owner').order).toEqual(defaultOrder('owner'));
  });
});
