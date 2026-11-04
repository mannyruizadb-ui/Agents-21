import { describe, expect, it } from 'vitest';
import { memoryStore, scopedStore } from '../../lib/scopedStore';
import { addPending, newTap, readPending } from '../../features/washroom/tapQueue';
import { pendingTotal, signOutWith, type PendingSource } from './signOutFlow';

function setup() {
  const base = memoryStore();
  const mine = scopedStore(base, 'userA');
  addPending(mine, newTap('washer1', null, 'tap1', new Date('2026-11-04T20:00:00Z')));
  const events: string[] = [];
  const source: PendingSource = {
    count: () => readPending(mine).length,
    flush: async () => {
      events.push('flush');
      // pretend the tap was sent
      mine.setItem('washerTaps.pending.v1', '[]');
    },
  };
  const signOut = async () => {
    events.push('signOut');
  };
  return { base, mine, source, events, signOut };
}

describe('guarded sign-out', () => {
  it('counts pending work across sources', () => {
    const { source } = setup();
    expect(pendingTotal([source, { count: () => 2, flush: async () => undefined }])).toBe(3);
  });

  it('Keep: signs out without sending and leaves the account storage untouched', async () => {
    const { base, source, events, signOut } = setup();
    const before = base.getItem('plantboard.userA.washerTaps.pending.v1');
    const r = await signOutWith('keep', [source], signOut);
    expect(events).toEqual(['signOut']);
    expect(r.stillPending).toBe(1);
    expect(base.getItem('plantboard.userA.washerTaps.pending.v1')).toBe(before);
  });

  it('Send now: sends first, then signs out', async () => {
    const { source, events, signOut } = setup();
    const r = await signOutWith('send', [source], signOut);
    expect(events).toEqual(['flush', 'signOut']);
    expect(r.stillPending).toBe(0);
  });

  it('Send now still signs out when sending fails, keeping what is left', async () => {
    const { mine, events, signOut } = setup();
    const failing: PendingSource = {
      count: () => readPending(mine).length,
      flush: async () => {
        throw new Error('offline');
      },
    };
    const r = await signOutWith('send', [failing], signOut);
    expect(events).toEqual(['signOut']);
    expect(r.stillPending).toBe(1);
  });
});
