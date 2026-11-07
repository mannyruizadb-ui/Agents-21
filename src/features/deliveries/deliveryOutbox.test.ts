import { describe, expect, it, vi } from 'vitest';
import { memoryStore } from '../../lib/scopedStore';
import { ENTRY_MAX_AGE_MS, PIN_MAX_AGE_MS } from '../estimates/estimateOutbox';
import {
  addPendingDelivery,
  DELIVERY_OUTBOX_KEY,
  dismissRejectedDelivery,
  flushDeliveries,
  readPendingDeliveries,
  readRejectedDeliveries,
  sweepDeliveries,
  updateDeliveryPin,
  type DeliveryApi,
  type PendingDelivery,
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
  staffId: 's1',
  pin: '1234',
  sessionId: null,
  createdAt: iso(NOW - 60_000),
  lastError: null,
  ...over,
});

function api(over: Partial<DeliveryApi> = {}): DeliveryApi & {
  record: ReturnType<typeof vi.fn>;
  startSession: ReturnType<typeof vi.fn>;
} {
  return {
    record: vi.fn(async () => ({ kind: 'saved' as const })),
    startSession: vi.fn(async () => ({ kind: 'ok' as const, sessionId: 'sess' })),
    ...over,
  } as never;
}

describe('delivery outbox', () => {
  it('stores before sending, sends with a new session, then wipes the record and PIN', async () => {
    const store = memoryStore();
    expect(addPendingDelivery(store, delivery())).toBe(true);
    expect(readPendingDeliveries(store)[0]?.pinStoredAt).toBe(iso(NOW - 60_000));
    const a = api();
    const r = await flushDeliveries(store, a, NOW);
    expect(a.startSession).toHaveBeenCalledWith('s1', '1234');
    expect(a.record).toHaveBeenCalledWith(expect.objectContaining({ clientId: 'c1' }), 'sess');
    expect(r.saved).toHaveLength(1);
    expect(readPendingDeliveries(store)).toEqual([]);
    expect(store.getItem(DELIVERY_OUTBOX_KEY)).not.toContain('1234');
  });

  it('reuses an open session and keeps the delivery when offline', async () => {
    const store = memoryStore();
    addPendingDelivery(store, delivery({ sessionId: 'open', pin: '' }));
    const a = api({ record: vi.fn(async () => ({ kind: 'retry' as const, error: 'NETWORK' })) });
    const r = await flushDeliveries(store, a, NOW);
    expect(a.startSession).not.toHaveBeenCalled();
    expect(r.remaining).toHaveLength(1);
    expect(r.remaining[0]?.lastError).toBe('NETWORK');
  });

  it('opens a new session when the old one is spent', async () => {
    const store = memoryStore();
    addPendingDelivery(store, delivery({ sessionId: 'spent' }));
    const record = vi
      .fn()
      .mockResolvedValueOnce({ kind: 'session' })
      .mockResolvedValueOnce({ kind: 'saved' });
    const a = api({ record });
    const r = await flushDeliveries(store, a, NOW);
    expect(record).toHaveBeenLastCalledWith(expect.anything(), 'sess');
    expect(r.saved).toHaveLength(1);
  });

  it('drops a refused PIN and asks for it again', async () => {
    const store = memoryStore();
    addPendingDelivery(store, delivery());
    const a = api({
      startSession: vi.fn(async () => ({ kind: 'pin' as const, error: 'PIN_INVALID' })),
    });
    const r = await flushDeliveries(store, a, NOW);
    expect(r.needsPin).toEqual({ staffId: 's1', error: 'PIN_INVALID' });
    expect(readPendingDeliveries(store)[0]).toMatchObject({ pin: '', lastError: 'PIN_INVALID' });
    expect(a.record).not.toHaveBeenCalled();
    updateDeliveryPin(store, 's1', '5678', NOW);
    expect(readPendingDeliveries(store)[0]).toMatchObject({ pin: '5678', lastError: null });
  });

  it('moves a refused delivery to the refused list without its PIN', async () => {
    const store = memoryStore();
    addPendingDelivery(store, delivery());
    const a = api({
      record: vi.fn(async () => ({ kind: 'rejected' as const, errorCode: 'VALIDATION_FAILED' })),
    });
    const r = await flushDeliveries(store, a, NOW);
    expect(r.rejected[0]).toMatchObject({ clientId: 'c1', errorCode: 'VALIDATION_FAILED' });
    expect(JSON.stringify(readRejectedDeliveries(store))).not.toContain('1234');
    dismissRejectedDelivery(store, 'c1');
    expect(readRejectedDeliveries(store)).toEqual([]);
  });

  it('stops before any call when the account changed', async () => {
    const store = memoryStore();
    addPendingDelivery(store, delivery());
    const a = api({ shouldContinue: async () => false });
    await flushDeliveries(store, a, NOW);
    expect(a.startSession).not.toHaveBeenCalled();
    expect(readPendingDeliveries(store)).toHaveLength(1);
  });

  it('sweeps too-old deliveries and old PINs without sending', () => {
    const store = memoryStore();
    addPendingDelivery(
      store,
      delivery({ clientId: 'old', enteredAt: iso(NOW - ENTRY_MAX_AGE_MS - 1) }),
    );
    addPendingDelivery(
      store,
      delivery({ clientId: 'pin', pinStoredAt: iso(NOW - PIN_MAX_AGE_MS - 1) }),
    );
    expect(sweepDeliveries(store, NOW)).toEqual({ tooOld: 1, pinsWiped: 1 });
    expect(readPendingDeliveries(store)).toMatchObject([
      { clientId: 'pin', pin: '', lastError: 'PIN_EXPIRED' },
    ]);
    expect(readRejectedDeliveries(store)[0]).toMatchObject({
      clientId: 'old',
      errorCode: 'OUT_OF_RANGE_TIMESTAMP',
    });
  });
});
