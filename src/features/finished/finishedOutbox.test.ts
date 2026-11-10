import { describe, expect, it } from 'vitest';
import { memoryStore } from '../../lib/scopedStore';
import {
  addPendingFinished,
  FINISHED_MAX_AGE_MS,
  flushFinished,
  markSavedVoided,
  readPendingFinished,
  readRejectedFinished,
  readSavedFinished,
  removePendingFinished,
  sweepFinished,
  type FinishedApi,
  type FinishedRecordOutcome,
  type PendingFinished,
} from './finishedOutbox';
import { mergeLines } from './finishedLines';
import { parseFgShift, type FgShiftData } from './finishedShift';

const NOW = Date.parse('2026-11-10T16:00:00Z');
const entry = (clientId: string, over: Partial<PendingFinished> = {}): PendingFinished => ({
  clientId,
  areaId: 'fin',
  itemTypeId: 'sheet',
  packs: 0,
  loose: 500,
  packSizeUsed: 10,
  enteredAt: new Date(NOW - 60_000).toISOString(),
  lastError: null,
  ...over,
});

function fakeApi(opts: { offlineAfter?: number; reject?: string } = {}) {
  let calls = 0;
  const sent: string[] = [];
  const api: FinishedApi = {
    async record(d): Promise<FinishedRecordOutcome> {
      calls += 1;
      if (opts.offlineAfter !== undefined && calls > opts.offlineAfter)
        return { kind: 'retry', error: 'NETWORK' };
      if (d.clientId === opts.reject) return { kind: 'rejected', errorCode: 'NOT_AUTHORIZED' };
      sent.push(d.clientId);
      return { kind: 'saved', id: `id-${d.clientId}`, pieces: 500, occurredAt: d.enteredAt };
    },
  };
  return { api, sent };
}

describe('finished-goods outbox', () => {
  it('stores before sending and keeps the client_id', async () => {
    const store = memoryStore();
    expect(addPendingFinished(store, entry('c1'))).toBe(true);
    expect(readPendingFinished(store)[0]?.clientId).toBe('c1');
    const { api, sent } = fakeApi();
    const r = await flushFinished(store, api, NOW);
    expect(sent).toEqual(['c1']);
    expect(r.saved).toHaveLength(1);
    expect(readPendingFinished(store)).toEqual([]);
    expect(readSavedFinished(store, NOW)[0]).toMatchObject({ clientId: 'c1', id: 'id-c1' });
  });

  it('offline: stops in order and keeps everything', async () => {
    const store = memoryStore();
    addPendingFinished(store, entry('c1'));
    addPendingFinished(store, entry('c2'));
    addPendingFinished(store, entry('c3'));
    const { api, sent } = fakeApi({ offlineAfter: 1 });
    const r = await flushFinished(store, api, NOW);
    expect(sent).toEqual(['c1']);
    expect(r.remaining.map((d) => d.clientId)).toEqual(['c2', 'c3']);
    expect(readPendingFinished(store)[0]?.lastError).toBe('NETWORK');
  });

  it('refused lines go to the refused list', async () => {
    const store = memoryStore();
    addPendingFinished(store, entry('c1'));
    addPendingFinished(store, entry('c2'));
    const { api, sent } = fakeApi({ reject: 'c1' });
    await flushFinished(store, api, NOW);
    expect(sent).toEqual(['c2']);
    expect(readRejectedFinished(store)).toMatchObject([
      { clientId: 'c1', errorCode: 'NOT_AUTHORIZED' },
    ]);
  });

  it('sweeps lines past the server window', () => {
    const store = memoryStore();
    addPendingFinished(
      store,
      entry('old', { enteredAt: new Date(NOW - FINISHED_MAX_AGE_MS - 1).toISOString() }),
    );
    addPendingFinished(store, entry('ok'));
    expect(sweepFinished(store, NOW)).toBe(1);
    expect(readPendingFinished(store).map((d) => d.clientId)).toEqual(['ok']);
    expect(readRejectedFinished(store)[0]).toMatchObject({
      clientId: 'old',
      errorCode: 'OUT_OF_RANGE_TIMESTAMP',
    });
  });

  it('Undo before sending takes the line off the device', async () => {
    const store = memoryStore();
    addPendingFinished(store, entry('c1'));
    expect(removePendingFinished(store, 'c1')).toBe(true);
    expect(removePendingFinished(store, 'c1')).toBe(false);
    const { api, sent } = fakeApi();
    await flushFinished(store, api, NOW);
    expect(sent).toEqual([]);
  });

  it('per-user scoped: another account never sees the lines', async () => {
    const { scopedStore } = await import('../../lib/scopedStore');
    const base = memoryStore();
    addPendingFinished(scopedStore(base, 'u1'), entry('c1'));
    expect(readPendingFinished(scopedStore(base, 'u2'))).toEqual([]);
    expect(readPendingFinished(scopedStore(base, 'u1'))).toHaveLength(1);
  });
});

describe('the shift lines on screen', () => {
  const data: FgShiftData = {
    area_id: 'fin',
    as_of: '2026-11-10T16:00:00Z',
    is_current: true,
    entries_hidden: false,
    shift: {
      id: 's',
      name: 'Day',
      starts_at: '2026-11-10T11:00:00Z',
      ends_at: '2026-11-10T19:30:00Z',
      production_date: '2026-11-10',
    },
    entries: [
      {
        id: 'e1',
        item_type_id: 'sheet',
        packs: 0,
        pack_size_used: 10,
        loose_pieces: 500,
        pieces: 500,
        occurred_at: '2026-11-10T12:00:00Z',
        client_id: 'c1',
      },
    ],
  };
  it('server + just saved + waiting, no doubles, voided ones gone', async () => {
    const store = memoryStore();
    addPendingFinished(store, entry('c1'));
    addPendingFinished(store, entry('c2'));
    await flushFinished(store, fakeApi().api, NOW);
    addPendingFinished(store, entry('c3', { packs: 2, loose: 0 }));
    const lines = mergeLines(
      data,
      readSavedFinished(store, NOW),
      readPendingFinished(store),
      'fin',
    );
    expect(lines.map((l) => [l.clientId, l.pending])).toEqual([
      ['c1', false],
      ['c2', false],
      ['c3', true],
    ]);
    expect(lines[2]?.pieces).toBe(20);
    markSavedVoided(store, 'id-c2', new Date(NOW).toISOString(), NOW);
    const after = mergeLines(data, readSavedFinished(store, NOW), [], 'fin');
    expect(after.map((l) => l.clientId)).toEqual(['c1']);
  });
  it('parses the RPC jsonb defensively', () => {
    expect(parseFgShift(null)).toBeNull();
    const p = parseFgShift({ ...data, entries: [...data.entries, { id: 1 }], shift: null });
    expect(p?.entries).toHaveLength(1);
    expect(p?.shift).toBeNull();
  });
});
