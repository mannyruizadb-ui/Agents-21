import { describe, expect, it } from 'vitest';
import { scopedStore } from '../lib/scopedStore';
import {
  addBatch,
  ENTRY_MAX_AGE_MS,
  OUTBOX_KEY,
  readOutbox,
  readRejectedEstimates,
  type OutboxBatch,
} from '../features/estimates/estimateOutbox';
import {
  addPendingDelivery,
  DELIVERY_OUTBOX_KEY,
  readPendingDeliveries,
  readRejectedDeliveries,
} from '../features/deliveries/deliveryOutbox';
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

const batch = (createdMs: number): OutboxBatch => ({
  batchId: `b${createdMs}`,
  entries: [{ clientId: `e${createdMs}`, washGroupId: 'g', qty: 1, unit: 'load' }],
  createdAt: new Date(createdMs).toISOString(),
  lastError: null,
});

describe('startup storage sweep (re-review notes 2 and 5)', () => {
  it('wipes entry-PIN-era PINs and too-old entries for every account, sending nothing', () => {
    const base = mapStore();
    // A: fresh entry saved by the old app with a PIN → PIN wiped, entry kept
    scopedStore(base, A).setItem(
      OUTBOX_KEY,
      JSON.stringify([{ ...batch(NOW - 60_000), staffId: 's1', pin: '1234', sessionId: null }]),
    );
    // B: entry older than the server accepts → refused list, batch gone
    addBatch(scopedStore(base, B), batch(NOW - ENTRY_MAX_AGE_MS - 1));
    const r = startupStorageSweep(base, NOW);
    expect(r).toMatchObject({ accounts: 2, legacyPinsWiped: 1, tooOld: 1 });
    const a = readOutbox(scopedStore(base, A));
    expect(a[0]?.entries).toHaveLength(1);
    expect(readOutbox(scopedStore(base, B))).toEqual([]);
    expect(readRejectedEstimates(scopedStore(base, B))[0]?.errorCode).toBe(
      'OUT_OF_RANGE_TIMESTAMP',
    );
    expect([...base.map.values()].join()).not.toContain('1234');
  });

  it("also sweeps every account's customer-delivery outbox", () => {
    const base = mapStore();
    const d = {
      plantId: 'p',
      customerId: 'aa',
      lines: [{ washGroupId: 'g', bins: 1 }],
      note: null,
      lastError: null,
    };
    scopedStore(base, A).setItem(
      DELIVERY_OUTBOX_KEY,
      JSON.stringify([
        {
          ...d,
          clientId: 'fresh-entry-old-pin',
          enteredAt: new Date(NOW - 60_000).toISOString(),
          createdAt: new Date(NOW - 60_000).toISOString(),
          staffId: 's1',
          pin: '1234',
          sessionId: null,
        },
      ]),
    );
    addPendingDelivery(scopedStore(base, B), {
      ...d,
      clientId: 'too-old',
      enteredAt: new Date(NOW - ENTRY_MAX_AGE_MS - 1).toISOString(),
      createdAt: new Date(NOW - ENTRY_MAX_AGE_MS - 1).toISOString(),
    });
    const r = startupStorageSweep(base, NOW);
    expect(r).toMatchObject({ legacyPinsWiped: 1, tooOld: 1 });
    expect(readPendingDeliveries(scopedStore(base, A))[0]?.clientId).toBe('fresh-entry-old-pin');
    expect(readPendingDeliveries(scopedStore(base, B))).toEqual([]);
    expect(readRejectedDeliveries(scopedStore(base, B))[0]?.clientId).toBe('too-old');
    expect([...base.map.values()].join()).not.toContain('1234');
  });

  it('leaves a fresh batch alone', () => {
    const base = mapStore();
    addBatch(scopedStore(base, A), batch(NOW - 60_000));
    const r = startupStorageSweep(base, NOW);
    expect(r).toMatchObject({ legacyPinsWiped: 0, tooOld: 0 });
    expect(readOutbox(scopedStore(base, A))).toHaveLength(1);
  });

  it('deletes the old unscoped keys once and touches nothing else', () => {
    const base = mapStore();
    for (const k of LEGACY_KEYS) base.setItem(k, '[{"pin":"1234"}]');
    base.setItem('plantboard.language', 'es');
    base.setItem(`plantboard.${A}.washerTaps.pending.v1`, '[]');
    base.setItem(`plantboard.${A}.estimates.lastStaff.v1`, 's1');
    base.setItem(`plantboard.${B}.staffSession.v1`, '{"sessionId":"x"}');
    const r = startupStorageSweep(base, NOW);
    expect(r.legacyRemoved).toBe(LEGACY_KEYS.length + 2);
    expect(base.keys().sort()).toEqual([
      `plantboard.${A}.washerTaps.pending.v1`,
      'plantboard.language',
    ]);
    expect(startupStorageSweep(base, NOW).legacyRemoved).toBe(0);
  });
});
