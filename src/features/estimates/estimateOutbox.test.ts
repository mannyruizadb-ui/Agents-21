import { describe, expect, it } from 'vitest';
import { memoryStore, scopedStore } from '../../lib/scopedStore';
import {
  addBatch,
  dismissRejectedEstimate,
  flushOutbox,
  OUTBOX_KEY,
  PIN_MAX_AGE_MS,
  readOutbox,
  readRejectedEstimates,
  updatePin,
  type OutboxApi,
  type OutboxBatch,
  type RecordOutcome,
  type SessionOutcome,
} from './estimateOutbox';

const batch = (over: Partial<OutboxBatch> = {}): OutboxBatch => ({
  batchId: 'b1',
  staffId: 's1',
  pin: '1234',
  sessionId: null,
  entries: [
    { clientId: 'e1', washGroupId: 'g1', qty: 2.5, unit: 'bin' },
    { clientId: 'e2', washGroupId: 'g2', qty: 0, unit: 'load' },
    { clientId: 'e3', washGroupId: 'g3', qty: 3, unit: 'load' },
  ],
  createdAt: '2026-11-04T22:00:00Z',
  lastError: null,
  ...over,
});

/** A fake server: single-use sessions (reuse window 0) unless `reuse` is true. */
function fakeApi(
  opts: { reuse?: boolean; pin?: string; offlineAfter?: number; reject?: string } = {},
) {
  const used = new Set<string>();
  let n = 0;
  let calls = 0;
  const log: string[] = [];
  const api: OutboxApi = {
    async startSession(_staff, pin): Promise<SessionOutcome> {
      calls += 1;
      if (opts.offlineAfter !== undefined && calls > opts.offlineAfter)
        return { kind: 'retry', error: 'network' };
      if (pin !== (opts.pin ?? '1234')) return { kind: 'pin', error: 'PIN_INVALID' };
      n += 1;
      log.push(`session${n}`);
      return { kind: 'ok', sessionId: `sess${n}` };
    },
    async record(e, sessionId): Promise<RecordOutcome> {
      calls += 1;
      if (opts.offlineAfter !== undefined && calls > opts.offlineAfter)
        return { kind: 'retry', error: 'network' };
      if (e.clientId === opts.reject) return { kind: 'rejected', errorCode: 'VALIDATION_FAILED' };
      if (used.has(sessionId)) return { kind: 'session' };
      if (!opts.reuse) used.add(sessionId);
      log.push(`${e.clientId}@${sessionId}`);
      return { kind: 'saved' };
    },
  };
  return { api, log };
}

describe('estimate outbox', () => {
  it('sends a batch with one PIN even when every session is single-use, then wipes the PIN', async () => {
    const s = memoryStore();
    addBatch(s, batch());
    const { api, log } = fakeApi();
    const r = await flushOutbox(s, api);
    expect(log).toEqual(['session1', 'e1@sess1', 'session2', 'e2@sess2', 'session3', 'e3@sess3']);
    expect(r.saved.map((e) => e.clientId)).toEqual(['e1', 'e2', 'e3']);
    expect(readOutbox(s)).toEqual([]);
    expect(s.getItem(OUTBOX_KEY)).not.toContain('1234');
  });

  it('reuses one session inside the server reuse window and reports it for the cache', async () => {
    const s = memoryStore();
    addBatch(s, batch({ sessionId: 'cached' }));
    const { api, log } = fakeApi({ reuse: true });
    const r = await flushOutbox(s, api);
    expect(log).toEqual(['e1@cached', 'e2@cached', 'e3@cached']);
    expect(r.sessions).toEqual([{ staffId: 's1', sessionId: 'cached' }]);
  });

  it('keeps unsent entries (and the PIN) when the connection drops, then finishes later', async () => {
    const s = memoryStore();
    addBatch(s, batch());
    await flushOutbox(s, fakeApi({ reuse: true, offlineAfter: 2 }).api);
    const left = readOutbox(s);
    expect(left).toHaveLength(1);
    expect(left[0]?.entries.map((e) => e.clientId)).toEqual(['e2', 'e3']);
    expect(left[0]?.pin).toBe('1234');
    expect(left[0]?.lastError).toBe('network');
    const r = await flushOutbox(s, fakeApi({ reuse: true }).api);
    expect(r.saved.map((e) => e.clientId)).toEqual(['e2', 'e3']);
    expect(readOutbox(s)).toEqual([]);
  });

  it('asks for the PIN again when it was changed, without losing the entries', async () => {
    const s = memoryStore();
    addBatch(s, batch());
    const r = await flushOutbox(s, fakeApi({ pin: '9999' }).api);
    expect(r.needsPin).toEqual({ staffId: 's1', error: 'PIN_INVALID' });
    expect(readOutbox(s)[0]?.entries).toHaveLength(3);
    updatePin(s, 's1', '9999');
    const r2 = await flushOutbox(s, fakeApi({ pin: '9999' }).api);
    expect(r2.saved).toHaveLength(3);
    expect(readOutbox(s)).toEqual([]);
  });

  it('moves a refused entry to the rejected list and sends the rest', async () => {
    const s = memoryStore();
    addBatch(s, batch());
    const r = await flushOutbox(s, fakeApi({ reuse: true, reject: 'e2' }).api);
    expect(r.saved.map((e) => e.clientId)).toEqual(['e1', 'e3']);
    expect(readRejectedEstimates(s).map((e) => [e.clientId, e.errorCode])).toEqual([
      ['e2', 'VALIDATION_FAILED'],
    ]);
    dismissRejectedEstimate(s, 'e2');
    expect(readRejectedEstimates(s)).toEqual([]);
  });

  it('does not loop when a brand-new session is refused', async () => {
    const s = memoryStore();
    addBatch(s, batch({ entries: [{ clientId: 'x', washGroupId: 'g', qty: 1, unit: 'load' }] }));
    const api: OutboxApi = {
      startSession: async () => ({ kind: 'ok', sessionId: 'new' }),
      record: async () => ({ kind: 'session' }),
    };
    const r = await flushOutbox(s, api);
    expect(r.rejected.map((e) => e.errorCode)).toEqual(['STAFF_SESSION_REQUIRED']);
    expect(readOutbox(s)).toEqual([]);
  });

  it('security M1: a wrong stored PIN reaches the server exactly once across many flushes', async () => {
    const s = memoryStore();
    addBatch(s, batch());
    let calls = 0;
    const api: OutboxApi = {
      startSession: async () => {
        calls += 1;
        return { kind: 'pin', error: 'PIN_INVALID' };
      },
      record: async () => ({ kind: 'saved' }),
    };
    for (let i = 0; i < 5; i++) {
      const r = await flushOutbox(s, api);
      expect(r.needsPin?.staffId).toBe('s1');
    }
    expect(calls).toBe(1);
    expect(readOutbox(s)[0]?.pin).toBe('');
    expect(readOutbox(s)[0]?.entries).toHaveLength(3);
  });

  it('security M2: a PIN older than 72 h is wiped, the entries kept, and the batch needs a PIN', async () => {
    const s = memoryStore();
    const created = Date.parse('2026-11-01T00:00:00Z');
    addBatch(s, batch({ createdAt: new Date(created).toISOString() }));
    let calls = 0;
    const api: OutboxApi = {
      startSession: async () => {
        calls += 1;
        return { kind: 'ok', sessionId: 'x' };
      },
      record: async () => ({ kind: 'saved' }),
    };
    const r = await flushOutbox(s, api, created + PIN_MAX_AGE_MS + 1);
    expect(calls).toBe(0);
    expect(r.needsPin).toEqual({ staffId: 's1', error: 'PIN_EXPIRED' });
    expect(readOutbox(s)[0]).toMatchObject({ pin: '', lastError: 'PIN_EXPIRED' });
    expect(readOutbox(s)[0]?.entries).toHaveLength(3);
    expect(s.getItem(OUTBOX_KEY)).not.toContain('1234');
  });

  it('a PIN inside 72 h is kept', async () => {
    const s = memoryStore();
    const created = Date.parse('2026-11-01T00:00:00Z');
    addBatch(s, batch({ createdAt: new Date(created).toISOString() }));
    await flushOutbox(s, fakeApi({ offlineAfter: 0 }).api, created + PIN_MAX_AGE_MS - 1000);
    expect(readOutbox(s)[0]?.pin).toBe('1234');
  });

  it("security H1: user B's store can't see A's batch, and B's flush never uses A's staff or PIN", async () => {
    const base = memoryStore();
    const a = scopedStore(base, 'userA');
    const b = scopedStore(base, 'userB');
    addBatch(a, batch());
    expect(readOutbox(b)).toEqual([]);
    const seen: string[] = [];
    const api: OutboxApi = {
      startSession: async (staffId, pin) => {
        seen.push(`${staffId}:${pin}`);
        return { kind: 'ok', sessionId: 'x' };
      },
      record: async () => ({ kind: 'saved' }),
    };
    const r = await flushOutbox(b, api);
    expect(seen).toEqual([]);
    expect(r.saved).toEqual([]);
    expect(readOutbox(a)).toHaveLength(1);
  });

  it('passes each entry with its own entered-at time to the server', async () => {
    const s = memoryStore();
    addBatch(
      s,
      batch({
        sessionId: 'sess',
        entries: [
          {
            clientId: 'e1',
            washGroupId: 'g',
            qty: 1,
            unit: 'load',
            enteredAt: '2026-11-04T22:00:00.000Z',
          },
        ],
      }),
    );
    const seen: (string | undefined)[] = [];
    await flushOutbox(s, {
      startSession: async () => ({ kind: 'ok', sessionId: 'x' }),
      record: async (e) => {
        seen.push(e.enteredAt);
        return { kind: 'saved' };
      },
    });
    expect(seen).toEqual(['2026-11-04T22:00:00.000Z']);
  });
});
