import { describe, expect, it } from 'vitest';
import {
  addPending,
  dismissRejected,
  flushPending,
  memoryStore,
  newTap,
  PENDING_KEY,
  readPending,
  readRejected,
  removePending,
  type KeyValueStore,
  type PendingTap,
  type SendOutcome,
} from './tapQueue';

const NOW = new Date('2026-11-04T20:00:00Z');
const tap = (id: string, machine = 'm1', group: string | null = null) =>
  newTap(machine, group, id, NOW);

describe('pending taps', () => {
  it('stores taps in order and ignores a duplicate clientId', () => {
    const s = memoryStore();
    expect(addPending(s, tap('a'))).toBe(true);
    addPending(s, tap('b', 'm2', 'g1'));
    addPending(s, tap('a'));
    expect(readPending(s).map((t) => t.clientId)).toEqual(['a', 'b']);
    expect(readPending(s)[1]).toMatchObject({ machineId: 'm2', washGroupId: 'g1', attempts: 0 });
  });

  it('removes an unsent tap on undo', () => {
    const s = memoryStore();
    addPending(s, tap('a'));
    expect(removePending(s, 'a')).toBe(true);
    expect(removePending(s, 'a')).toBe(false);
    expect(readPending(s)).toEqual([]);
  });

  it('survives corrupt storage and drops malformed entries', () => {
    const s = memoryStore();
    s.setItem(PENDING_KEY, '{not json');
    expect(readPending(s)).toEqual([]);
    s.setItem(PENDING_KEY, JSON.stringify([{ clientId: 1 }, tap('ok')]));
    expect(readPending(s).map((t) => t.clientId)).toEqual(['ok']);
  });

  it('reports a storage failure instead of throwing', () => {
    const broken: KeyValueStore = {
      getItem: () => null,
      setItem: () => {
        throw new Error('QuotaExceededError');
      },
    };
    expect(addPending(broken, tap('a'))).toBe(false);
    expect(
      readPending({
        getItem: () => {
          throw new Error('denied');
        },
        setItem: () => {},
      }),
    ).toEqual([]);
  });
});

describe('flushPending', () => {
  it('sends oldest first and removes each sent tap', async () => {
    const s = memoryStore();
    addPending(s, tap('a'));
    addPending(s, tap('b'));
    const order: string[] = [];
    const r = await flushPending(s, async (t): Promise<SendOutcome<string>> => {
      order.push(t.clientId);
      return { kind: 'sent', result: `cycle-${t.clientId}` };
    });
    expect(order).toEqual(['a', 'b']);
    expect(r.sent.map((x) => x.result)).toEqual(['cycle-a', 'cycle-b']);
    expect(r.remaining).toEqual([]);
    expect(readPending(s)).toEqual([]);
  });

  it('stops at a temporary failure and keeps the rest in order, counting the attempt', async () => {
    const s = memoryStore();
    addPending(s, tap('a'));
    addPending(s, tap('b'));
    const sent: string[] = [];
    const r = await flushPending(s, async (t): Promise<SendOutcome<null>> => {
      sent.push(t.clientId);
      return { kind: 'retry', error: 'offline' };
    });
    expect(sent).toEqual(['a']);
    expect(r.remaining.map((t) => t.clientId)).toEqual(['a', 'b']);
    expect(r.remaining[0]).toMatchObject({ attempts: 1, lastError: 'offline' });
    expect(r.remaining[1]).toMatchObject({ attempts: 0 });
  });

  it('moves a rejected tap to the rejected list and keeps going', async () => {
    const s = memoryStore();
    addPending(s, tap('bad'));
    addPending(s, tap('good'));
    const r = await flushPending(
      s,
      async (t): Promise<SendOutcome<number>> =>
        t.clientId === 'bad'
          ? { kind: 'rejected', errorCode: 'VALIDATION_FAILED' }
          : { kind: 'sent', result: 1 },
      () => NOW,
    );
    expect(r.sent).toHaveLength(1);
    expect(readPending(s)).toEqual([]);
    const rejected = readRejected(s);
    expect(rejected).toHaveLength(1);
    expect(rejected[0]).toMatchObject({
      clientId: 'bad',
      errorCode: 'VALIDATION_FAILED',
      rejectedAt: NOW.toISOString(),
    });
    dismissRejected(s, 'bad');
    expect(readRejected(s)).toEqual([]);
  });

  it('picks up a tap added during the flush and does not resurrect one undone during it', async () => {
    const s = memoryStore();
    addPending(s, tap('a'));
    addPending(s, tap('b'));
    const seen: string[] = [];
    await flushPending(s, async (t: PendingTap): Promise<SendOutcome<null>> => {
      seen.push(t.clientId);
      if (t.clientId === 'a') {
        removePending(s, 'b'); // undone while 'a' was in flight
        addPending(s, tap('c')); // tapped while 'a' was in flight
      }
      return { kind: 'sent', result: null };
    });
    expect(seen).toEqual(['a', 'c']);
    expect(readPending(s)).toEqual([]);
  });

  it('a retry that was undone meanwhile is not written back', async () => {
    const s = memoryStore();
    addPending(s, tap('a'));
    await flushPending(s, async (): Promise<SendOutcome<null>> => {
      removePending(s, 'a');
      return { kind: 'retry', error: 'offline' };
    });
    expect(readPending(s)).toEqual([]);
  });
});
