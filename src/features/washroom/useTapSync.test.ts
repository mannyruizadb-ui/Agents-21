import { beforeEach, describe, expect, it, vi } from 'vitest';

// The race behind "undo + restart lost a load": UNDO pressed while the START is still on the wire.
const rpc = vi.fn();
vi.mock('../../lib/supabase', () => ({ supabase: { rpc: (...a: unknown[]) => rpc(...a) } }));
vi.mock('../../lib/authUser', () => ({ isSignedInAs: async () => true }));
vi.mock('../../app/auth/sessionContext', () => ({ useRequiredSession: () => ({}) }));

import { userStore } from '../../lib/scopedStore';
import { addPending, newTap, readPending, readRejected } from './tapQueue';
import { flushTaps, undoTap } from './useTapSync';

function deferred<T>() {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

describe('undoTap', () => {
  beforeEach(() => rpc.mockReset());

  it('voids the cycle on the server when UNDO races an in-flight START', async () => {
    const user = 'user-race';
    addPending(userStore(user), newTap('washer-1', null, 'tap-1', new Date()));
    const start = deferred<{ data: unknown; error: null }>();
    rpc.mockImplementation((fn: string) =>
      fn === 'start_washer_load' ? start.promise : Promise.resolve({ data: {}, error: null }),
    );

    const flushing = flushTaps(user); // START is now on the wire
    await Promise.resolve();
    const undoing = undoTap(user, 'tap-1'); // UNDO pressed before the server answered
    start.resolve({ data: { cycle_id: 'cycle-1', duplicate: false }, error: null });
    await flushing;
    await undoing;

    expect(rpc).toHaveBeenCalledWith('undo_washer_load', { p_cycle_id: 'cycle-1' });
    expect(readPending(userStore(user))).toHaveLength(0);
  });

  it('drops a tap that never reached the server without calling it', async () => {
    const user = 'user-offline';
    addPending(userStore(user), newTap('washer-1', null, 'tap-2', new Date()));
    await undoTap(user, 'tap-2');
    expect(rpc).not.toHaveBeenCalled();
    expect(readPending(userStore(user))).toHaveLength(0);
  });
});

describe('sendTap', () => {
  beforeEach(() => rpc.mockReset());

  it('sends the off-queue reason and the running confirmation with the tap', async () => {
    const user = 'user-reason';
    addPending(userStore(user), newTap('washer-2', 'group-9', 'tap-3', new Date(), true, 'urgent'));
    rpc.mockResolvedValue({ data: { cycle_id: 'c', duplicate: false }, error: null });
    await flushTaps(user);
    expect(rpc).toHaveBeenCalledWith(
      'start_washer_load',
      expect.objectContaining({
        p_client_id: 'tap-3',
        p_wash_group_id: 'group-9',
        p_confirm_running: true,
        p_off_queue_reason: 'urgent',
      }),
    );
  });

  it('keeps a tap the server refuses for a missing reason (never lost)', async () => {
    const user = 'user-noreason';
    addPending(userStore(user), newTap('washer-2', 'group-9', 'tap-4', new Date()));
    rpc.mockResolvedValue({
      data: null,
      error: { message: 'OFF_QUEUE_REASON_REQUIRED', details: 'expected_wash_group_id=none' },
    });
    await flushTaps(user);
    const call = rpc.mock.calls[0]?.[1] as Record<string, unknown>;
    expect(call).not.toHaveProperty('p_off_queue_reason');
    expect(readRejected(userStore(user)).map((r) => r.errorCode)).toEqual([
      'OFF_QUEUE_REASON_REQUIRED',
    ]);
  });
});
