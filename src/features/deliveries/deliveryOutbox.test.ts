import { describe, expect, it, vi } from 'vitest';
import { memoryStore } from '../../lib/scopedStore';
import { ENTRY_MAX_AGE_MS } from '../estimates/estimateOutbox';
import {
  addPendingDelivery,
  DELIVERY_OUTBOX_KEY,
  dismissRejectedDelivery,
  flushDeliveries,
  markRecentVoided,
  readPendingDeliveries,
  readRecentDeliveries,
  readRejectedDeliveries,
  RECENT_MAX,
  RECENT_MAX_AGE_MS,
  rememberRecentDelivery,
  sweepDeliveries,
  type DeliveryApi,
  type PendingDelivery,
  type RecentDelivery,
} from './deliveryOutbox';

const NOW = Date.parse('2026-11-07T10:00:00Z');
const iso = (ms: number) => new Date(ms).toISOString();

const delivery = (over: Partial<PendingDelivery> = {}): PendingDelivery => ({
  clientId: 'c1',
  plantId: 'p',
  customerId: 'aa',
  lines: [{ washGroupId: 'g', bins: 1.5 }],
  note: null,
  enteredAt: iso(NOW - 60_000),
  createdAt: iso(NOW - 60_000),
  lastError: null,
  ...over,
});

function api(over: Partial<DeliveryApi> = {}): DeliveryApi & {
  record: ReturnType<typeof vi.fn>;
} {
  return {
    record: vi.fn(async () => ({ kind: 'saved' as const, deliveryId: 'd1', queueItemIds: ['q1'] })),
    ...over,
  } as never;
}

describe('delivery outbox', () => {
  it('stores before sending, sends, then removes it and remembers the saved delivery', async () => {
    const store = memoryStore();
    expect(addPendingDelivery(store, delivery())).toBe(true);
    const a = api();
    const r = await flushDeliveries(store, a, NOW);
    expect(a.record).toHaveBeenCalledWith(expect.objectContaining({ clientId: 'c1' }));
    expect(r.saved).toHaveLength(1);
    expect(readPendingDeliveries(store)).toEqual([]);
    expect(readRecentDeliveries(store, NOW)).toMatchObject([
      { deliveryId: 'd1', clientId: 'c1', queueItemIds: ['q1'], customerId: 'aa' },
    ]);
  });

  it('keeps the delivery when offline', async () => {
    const store = memoryStore();
    addPendingDelivery(store, delivery());
    const a = api({ record: vi.fn(async () => ({ kind: 'retry' as const, error: 'NETWORK' })) });
    const r = await flushDeliveries(store, a, NOW);
    expect(r.remaining).toHaveLength(1);
    expect(r.remaining[0]?.lastError).toBe('NETWORK');
    expect(readRecentDeliveries(store, NOW)).toEqual([]);
  });

  it('moves a refused delivery to the refused list', async () => {
    const store = memoryStore();
    addPendingDelivery(store, delivery());
    const a = api({
      record: vi.fn(async () => ({ kind: 'rejected' as const, errorCode: 'VALIDATION_FAILED' })),
    });
    const r = await flushDeliveries(store, a, NOW);
    expect(r.rejected[0]).toMatchObject({ clientId: 'c1', errorCode: 'VALIDATION_FAILED' });
    dismissRejectedDelivery(store, 'c1');
    expect(readRejectedDeliveries(store)).toEqual([]);
  });

  it('stops before any call when the account changed', async () => {
    const store = memoryStore();
    addPendingDelivery(store, delivery());
    const a = api({ shouldContinue: async () => false });
    await flushDeliveries(store, a, NOW);
    expect(a.record).not.toHaveBeenCalled();
    expect(readPendingDeliveries(store)).toHaveLength(1);
  });

  it('sweeps too-old deliveries without sending', () => {
    const store = memoryStore();
    addPendingDelivery(
      store,
      delivery({ clientId: 'old', enteredAt: iso(NOW - ENTRY_MAX_AGE_MS - 1) }),
    );
    addPendingDelivery(store, delivery({ clientId: 'ok' }));
    expect(sweepDeliveries(store, NOW)).toEqual({ tooOld: 1, legacyWiped: 0 });
    expect(readPendingDeliveries(store).map((d) => d.clientId)).toEqual(['ok']);
    expect(readRejectedDeliveries(store)[0]).toMatchObject({
      clientId: 'old',
      errorCode: 'OUT_OF_RANGE_TIMESTAMP',
    });
  });

  it('a delivery stored before 2026-11-07 (with a staff PIN) is still sent; its PIN is wiped', async () => {
    const store = memoryStore();
    store.setItem(
      DELIVERY_OUTBOX_KEY,
      JSON.stringify([{ ...delivery(), staffId: 's1', pin: '1234', sessionId: null }]),
    );
    expect(readPendingDeliveries(store)).toEqual([delivery()]);
    expect(sweepDeliveries(store, NOW).legacyWiped).toBe(1);
    expect(store.getItem(DELIVERY_OUTBOX_KEY)).not.toContain('1234');
    const r = await flushDeliveries(store, api(), NOW);
    expect(r.saved).toHaveLength(1);
  });
});

describe('recent deliveries (cancel from this phone)', () => {
  const recent = (id: string, at: number): RecentDelivery => ({
    deliveryId: id,
    clientId: `c-${id}`,
    plantId: 'p',
    customerId: 'aa',
    lines: [{ washGroupId: 'g', bins: 1 }],
    queueItemIds: ['q'],
    savedAt: iso(at),
  });

  it(`keeps the newest ${RECENT_MAX}, newest first`, () => {
    const store = memoryStore();
    for (let i = 0; i < RECENT_MAX + 2; i++)
      rememberRecentDelivery(store, recent(`d${i}`, NOW + i), NOW);
    const list = readRecentDeliveries(store, NOW);
    expect(list).toHaveLength(RECENT_MAX);
    expect(list[0]?.deliveryId).toBe(`d${RECENT_MAX + 1}`);
  });

  it('forgets deliveries older than the window and marks cancelled ones', () => {
    const store = memoryStore();
    rememberRecentDelivery(store, recent('old', NOW - RECENT_MAX_AGE_MS - 1), NOW);
    rememberRecentDelivery(store, recent('new', NOW), NOW);
    expect(readRecentDeliveries(store, NOW).map((r) => r.deliveryId)).toEqual(['new']);
    markRecentVoided(store, 'new', iso(NOW), NOW);
    expect(readRecentDeliveries(store, NOW)[0]?.voidedAt).toBe(iso(NOW));
  });
});
