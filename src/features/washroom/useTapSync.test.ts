import { beforeEach, describe, expect, it, vi } from 'vitest';

// The race behind "undo + restart lost a load": UNDO pressed while the START is still on the wire.
const rpc = vi.fn();
vi.mock('../../lib/supabase', () => ({ supabase: { rpc: (...a: unknown[]) => rpc(...a) } }));
vi.mock('../../lib/authUser', () => ({ isSignedInAs: async () => true }));
vi.mock('../../app/auth/sessionContext', () => ({ useRequiredSession: () => ({}) }));

import { userStore } from '../../lib/scopedStore';
import { addPending, newTap, readPending } from './tapQueue';
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
