import { describe, expect, it } from 'vitest';
import { scopedStore } from '../lib/scopedStore';
import {
  addBatch,
  ENTRY_MAX_AGE_MS,
  PIN_MAX_AGE_MS,
  readOutbox,
  readRejectedEstimates,
  type OutboxBatch,
} from '../features/estimates/estimateOutbox';
import { LEGACY_KEYS, startupStorageSweep, type EnumerableStore } from './startupStorage';

function mapStore(): EnumerableStore & { map: Map<string, string> } {
  const map = new Map<string, string>();
  return {
    map,
    keys: () => [...map.keys()],
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => {
      map.set(k, v);
    },
    removeItem: (k) => {
      map.delete(k);
    },
  };
}

const A = '0af3675d-8679-4c45-b819-1678c64d88e8';
const B = '11111111-2222-3333-4444-555555555555';
const NOW = Date.parse('2026-11-05T12:00:00Z');

const batch = (createdMs: number, pinMs: number): OutboxBatch => ({
  batchId: `b${createdMs}`,
  staffId: 's1',
  pin: '1234',
  pinStoredAt: new Date(pinMs).toISOString(),
  sessionId: null,
  entries: [{ clientId: `e${createdMs}`, washGroupId: 'g', qty: 1, unit: 'load' }],
  createdAt: new Date(createdMs).toISOString(),
  lastError: null,
});

describe('startup storage sweep (re-review notes 2 and 5)', () => {
  it('wipes expired PINs and too-old entries for every account, sending nothing', () => {
    const base = mapStore();
    // A: fresh entry, but its PIN was stored > 6 h ago → PIN wiped, entry kept
    addBatch(scopedStore(base, A), batch(NOW - 60_000, NOW - PIN_MAX_AGE_MS - 1));
    // B: entry older than the server accepts → refused list, batch (and PIN) gone
    addBatch(scopedStore(base, B), batch(NOW - ENTRY_MAX_AGE_MS - 1, NOW - ENTRY_MAX_AGE_MS - 1));
    const r = startupStorageSweep(base, NOW);
    expect(r).toMatchObject({ accounts: 2, pinsWiped: 1, tooOld: 1 });
    const a = readOutbox(scopedStore(base, A));
    expect(a[0]).toMatchObject({ pin: '', lastError: 'PIN_EXPIRED' });
    expect(a[0]?.entries).toHaveLength(1);
    expect(readOutbox(scopedStore(base, B))).toEqual([]);
    expect(readRejectedEstimates(scopedStore(base, B))[0]?.errorCode).toBe(
      'OUT_OF_RANGE_TIMESTAMP',
    );
    expect([...base.map.values()].join()).not.toContain('1234');
  });

  it('leaves a fresh batch and its PIN alone', () => {
    const base = mapStore();
    addBatch(scopedStore(base, A), batch(NOW - 60_000, NOW - 60_000));
    startupStorageSweep(base, NOW);
    expect(readOutbox(scopedStore(base, A))[0]?.pin).toBe('1234');
  });

  it('deletes the old unscoped keys once and touches nothing else', () => {
    const base = mapStore();
    for (const k of LEGACY_KEYS) base.setItem(k, '[{"pin":"1234"}]');
    base.setItem('plantboard.language', 'es');
    base.setItem(`plantboard.${A}.washerTaps.pending.v1`, '[]');
    const r = startupStorageSweep(base, NOW);
    expect(r.legacyRemoved).toBe(LEGACY_KEYS.length);
    expect(base.keys().sort()).toEqual([
      `plantboard.${A}.washerTaps.pending.v1`,
      'plantboard.language',
    ]);
    expect(startupStorageSweep(base, NOW).legacyRemoved).toBe(0);
  });
});
