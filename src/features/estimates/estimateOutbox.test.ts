import { describe, expect, it } from 'vitest';
import { memoryStore, scopedStore } from '../../lib/scopedStore';
import {
  addBatch,
  dismissRejectedEstimate,
  flushOutbox,
  ENTRY_MAX_AGE_MS,
  OUTBOX_KEY,
  readOutbox,
  readRejectedEstimates,
  sweepOutbox,
  type OutboxApi,
  type OutboxBatch,
  type RecordOutcome,
} from './estimateOutbox';

const batch = (over: Partial<OutboxBatch> = {}): OutboxBatch => ({
  batchId: 'b1',
  entries: [
    { clientId: 'e1', washGroupId: 'g1', qty: 2.5, unit: 'bin' },
    { clientId: 'e2', washGroupId: 'g2', qty: 0, unit: 'load' },
    { clientId: 'e3', washGroupId: 'g3', qty: 3, unit: 'load' },
  ],
  createdAt: new Date().toISOString(),
  lastError: null,
  ...over,
});

/** A fake server. */
function fakeApi(opts: { offlineAfter?: number; reject?: string } = {}) {
  let calls = 0;
  const log: string[] = [];
  const api: OutboxApi = {
    async record(e): Promise<RecordOutcome> {
      calls += 1;
      if (opts.offlineAfter !== undefined && calls > opts.offlineAfter)
        return { kind: 'retry', error: 'network' };
      if (e.clientId === opts.reject) return { kind: 'rejected', errorCode: 'VALIDATION_FAILED' };
      log.push(e.clientId);
      return { kind: 'saved' };
    },
  };
  return { api, log };
}

describe('estimate outbox', () => {
  it('sends a batch in order and empties the outbox', async () => {
    const s = memoryStore();
    addBatch(s, batch());
    const { api, log } = fakeApi();
    const r = await flushOutbox(s, api);
    expect(log).toEqual(['e1', 'e2', 'e3']);
    expect(r.saved.map((e) => e.clientId)).toEqual(['e1', 'e2', 'e3']);
    expect(readOutbox(s)).toEqual([]);
  });

  it('keeps unsent entries when the connection drops, then finishes later', async () => {
    const s = memoryStore();
    addBatch(s, batch());
    await flushOutbox(s, fakeApi({ offlineAfter: 1 }).api);
    const left = readOutbox(s);
    expect(left).toHaveLength(1);
    expect(left[0]?.entries.map((e) => e.clientId)).toEqual(['e2', 'e3']);
    expect(left[0]?.lastError).toBe('network');
    const r = await flushOutbox(s, fakeApi().api);
    expect(r.saved.map((e) => e.clientId)).toEqual(['e2', 'e3']);
    expect(readOutbox(s)).toEqual([]);
  });

  it('moves a refused entry to the rejected list and sends the rest', async () => {
    const s = memoryStore();
    addBatch(s, batch());
    const r = await flushOutbox(s, fakeApi({ reject: 'e2' }).api);
    expect(r.saved.map((e) => e.clientId)).toEqual(['e1', 'e3']);
    expect(readRejectedEstimates(s).map((e) => [e.clientId, e.errorCode])).toEqual([
      ['e2', 'VALIDATION_FAILED'],
    ]);
    dismissRejectedEstimate(s, 'e2');
    expect(readRejectedEstimates(s)).toEqual([]);
  });

  it('entries older than 6 h move to the refused list as OUT_OF_RANGE_TIMESTAMP, unsent', async () => {
    const s = memoryStore();
    const now = Date.parse('2026-11-04T22:00:00Z');
    addBatch(s, batch({ createdAt: new Date(now - ENTRY_MAX_AGE_MS - 1000).toISOString() }));
    const { api, log } = fakeApi();
    const r = await flushOutbox(s, api, now);
    expect(log).toEqual([]);
    expect(r.rejected.map((e) => e.errorCode)).toEqual([
      'OUT_OF_RANGE_TIMESTAMP',
      'OUT_OF_RANGE_TIMESTAMP',
      'OUT_OF_RANGE_TIMESTAMP',
    ]);
    expect(readOutbox(s)).toEqual([]);
    expect(readRejectedEstimates(s)).toHaveLength(3);
  });

  it('an entry inside 6 h is kept and sent', async () => {
    const s = memoryStore();
    const now = Date.parse('2026-11-04T22:00:00Z');
    addBatch(s, batch({ createdAt: new Date(now - ENTRY_MAX_AGE_MS + 60_000).toISOString() }));
    const r = await flushOutbox(s, fakeApi().api, now);
    expect(r.saved).toHaveLength(3);
  });

  it('a batch saved before 2026-11-07 (with a staff PIN) is still sent, and its PIN is wiped', async () => {
    const s = memoryStore();
    const legacy = { ...batch(), staffId: 's1', pin: '1234', sessionId: 'old', pinStoredAt: 'x' };
    s.setItem(OUTBOX_KEY, JSON.stringify([legacy]));
    expect(readOutbox(s)[0]).toEqual(batch({ createdAt: legacy.createdAt }));
    expect(sweepOutbox(s).legacyWiped).toBe(1);
    expect(s.getItem(OUTBOX_KEY)).not.toContain('1234');
    const r = await flushOutbox(s, fakeApi().api);
    expect(r.saved).toHaveLength(3);
  });

  it('a flush stops at once when the account changes mid-flush', async () => {
    const s = memoryStore();
    addBatch(s, batch());
    let signedIn = true;
    const recorded: string[] = [];
    const api: OutboxApi = {
      shouldContinue: async () => signedIn,
      record: async (e) => {
        recorded.push(e.clientId);
        signedIn = false; // the account signs out after the first save
        return { kind: 'saved' };
      },
    };
    await flushOutbox(s, api);
    expect(recorded).toEqual(['e1']);
    expect(readOutbox(s)[0]?.entries.map((e) => e.clientId)).toEqual(['e2', 'e3']);
  });

  it("security H1: user B's store can't see A's batch", async () => {
    const base = memoryStore();
    const a = scopedStore(base, 'userA');
    const b = scopedStore(base, 'userB');
    addBatch(a, batch());
    expect(readOutbox(b)).toEqual([]);
    const { api, log } = fakeApi();
    const r = await flushOutbox(b, api);
    expect(log).toEqual([]);
    expect(r.saved).toEqual([]);
    expect(readOutbox(a)).toHaveLength(1);
  });

  it('passes each entry with its own entered-at time to the server', async () => {
    const s = memoryStore();
    const enteredAt = new Date(Date.now() - 60_000).toISOString();
    addBatch(
      s,
      batch({ entries: [{ clientId: 'e1', washGroupId: 'g', qty: 1, unit: 'load', enteredAt }] }),
    );
    const seen: (string | undefined)[] = [];
    await flushOutbox(s, {
      record: async (e) => {
        seen.push(e.enteredAt);
        return { kind: 'saved' };
      },
    });
    expect(seen).toEqual([enteredAt]);
  });
});
