import { useCallback, useEffect, useMemo, useSyncExternalStore } from 'react';
import { useQueryClient, type QueryClient } from '@tanstack/react-query';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { isSignedInAs } from '../../lib/authUser';
import { isBrowserStorePersistent, scopedKey, userStore } from '../../lib/scopedStore';
import { supabase } from '../../lib/supabase';
import type { Database } from '../../types/database';
import { isRetryable, toRpcError, unwrap } from './rpcError';
import {
  addPending,
  dismissRejected,
  flushPending,
  newTap,
  PENDING_KEY,
  readPending,
  readRejected,
  REJECTED_KEY,
  removePending,
  type PendingTap,
  type RejectedTap,
  type SendOutcome,
} from './tapQueue';

// Washer start-taps that never get lost (client_id generated before the first attempt; taps persist
// offline). Security H1: everything lives in the signed-in account's own storage
// (plantboard.<userId>.…); a flush reads only that account's taps and checks the account is still
// signed in right before sending. One flusher per account per tab; the server's client_id
// idempotency makes a double send from two tabs harmless.

export type WasherLoadResult = Database['public']['CompositeTypes']['washer_load_result'];

/** How long the station offers UNDO after a start (the server allows 30 minutes). */
export const UNDO_WINDOW_MS = 60_000;
const RETRY_EVERY_MS = 15_000;

export interface TapSnapshot {
  pending: PendingTap[];
  rejected: RejectedTap[];
  /** Results of taps sent from this tab, by client_id (for UNDO and the "Started" message). */
  sent: Record<string, WasherLoadResult>;
  /** false = this device can't keep taps across a reload; the screen says so. */
  persistent: boolean;
}

interface UserState {
  snapshot: TapSnapshot;
  sent: Record<string, WasherLoadResult>;
  flushing: Promise<void> | null;
}

const users = new Map<string, UserState>();
const listeners = new Set<() => void>();

function state(userId: string): UserState {
  let s = users.get(userId);
  if (!s) {
    const store = userStore(userId);
    s = {
      sent: {},
      flushing: null,
      snapshot: {
        pending: readPending(store),
        rejected: readRejected(store),
        sent: {},
        persistent: isBrowserStorePersistent(),
      },
    };
    users.set(userId, s);
  }
  return s;
}

function refresh(userId: string) {
  const s = state(userId);
  const store = userStore(userId);
  s.snapshot = {
    pending: readPending(store),
    rejected: readRejected(store),
    sent: s.sent,
    persistent: isBrowserStorePersistent(),
  };
  for (const l of listeners) l();
}

function subscribeFor(userId: string) {
  return (listener: () => void) => {
    listeners.add(listener);
    const onStorage = (e: StorageEvent) => {
      if (e.key === scopedKey(userId, PENDING_KEY) || e.key === scopedKey(userId, REJECTED_KEY)) {
        refresh(userId);
      }
    };
    window.addEventListener('storage', onStorage);
    return () => {
      listeners.delete(listener);
      window.removeEventListener('storage', onStorage);
    };
  };
}

async function sendTap(tap: PendingTap): Promise<SendOutcome<WasherLoadResult>> {
  try {
    const res = await supabase.rpc('start_washer_load', {
      p_machine_id: tap.machineId,
      p_client_id: tap.clientId,
      // The tap's own time (server-clock corrected at tap time), so an offline tap that syncs later
      // still starts the cycle when the washer was loaded. Older than 30 min → OUT_OF_RANGE_TIMESTAMP.
      p_tapped_at: tap.tappedAt,
      ...(tap.washGroupId ? { p_wash_group_id: tap.washGroupId } : {}),
    });
    if (res.error) {
      const e = toRpcError(res.error);
      return isRetryable(e)
        ? { kind: 'retry', error: e.code ?? 'NETWORK' }
        : { kind: 'rejected', errorCode: e.code ?? 'UNKNOWN' };
    }
    return { kind: 'sent', result: res.data };
  } catch {
    return { kind: 'retry', error: 'NETWORK' };
  }
}

/** Sends this account's waiting taps (only while it is the signed-in account). */
export function flushTaps(userId: string, qc?: QueryClient): Promise<void> {
  const s = state(userId);
  if (s.flushing) return s.flushing;
  s.flushing = (async () => {
    try {
      if (!(await isSignedInAs(userId))) return;
      const r = await flushPending(userStore(userId), sendTap);
      if (r.sent.length > 0) {
        s.sent = { ...s.sent };
        for (const x of r.sent) s.sent[x.tap.clientId] = x.result;
      }
      if (qc && (r.sent.length > 0 || r.rejected.length > 0)) {
        void qc.invalidateQueries({ queryKey: ['washroom-board'] });
        void qc.invalidateQueries({ queryKey: ['queue'] });
      }
    } finally {
      s.flushing = null;
      refresh(userId);
    }
  })();
  return s.flushing;
}

/** How many taps this account has waiting (for the guarded sign-out). */
export function pendingTapCount(userId: string): number {
  return readPending(userStore(userId)).length;
}

export function useTapSync() {
  const userId = useRequiredSession().user.id;
  const qc = useQueryClient();
  const subscribe = useMemo(() => subscribeFor(userId), [userId]);
  const getSnapshot = useCallback(() => state(userId).snapshot, [userId]);
  const snap = useSyncExternalStore(subscribe, getSnapshot);
  const hasPending = snap.pending.length > 0;

  // Retry on mount, when the device comes back online, and every 15 s while anything is waiting.
  useEffect(() => {
    const run = () => void flushTaps(userId, qc);
    if (readPending(userStore(userId)).length > 0) run();
    window.addEventListener('online', run);
    const id = hasPending ? window.setInterval(run, RETRY_EVERY_MS) : undefined;
    return () => {
      window.removeEventListener('online', run);
      if (id !== undefined) window.clearInterval(id);
    };
  }, [userId, qc, hasPending]);

  /**
   * Records a start-tap on the device first, then sends it. Returns its client_id. `clockOffsetMs`
   * = server clock − device clock (from the board's server_time), so a tablet whose clock runs fast
   * doesn't send a tap time in the future (the server allows at most 1 minute ahead).
   */
  const tap = useCallback(
    (machineId: string, washGroupId: string | null, clockOffsetMs = 0): string => {
      const clientId = crypto.randomUUID();
      addPending(
        userStore(userId),
        newTap(machineId, washGroupId, clientId, new Date(Date.now() + clockOffsetMs)),
      );
      refresh(userId);
      void flushTaps(userId, qc);
      return clientId;
    },
    [userId, qc],
  );

  /**
   * Undo a start. Not sent yet → removed from the device (it never reaches the server). Sent → the
   * server voids the cycle. Throws an RpcError if the server refuses or can't be reached.
   */
  const undo = useCallback(
    async (clientId: string): Promise<void> => {
      if (removePending(userStore(userId), clientId)) {
        refresh(userId);
        return;
      }
      const s = state(userId);
      const result = s.sent[clientId];
      if (!result?.cycle_id) return;
      unwrap(await supabase.rpc('undo_washer_load', { p_cycle_id: result.cycle_id }));
      s.sent = Object.fromEntries(Object.entries(s.sent).filter(([k]) => k !== clientId));
      refresh(userId);
      void qc.invalidateQueries({ queryKey: ['washroom-board'] });
      void qc.invalidateQueries({ queryKey: ['queue'] });
    },
    [userId, qc],
  );

  const dismiss = useCallback(
    (clientId: string) => {
      dismissRejected(userStore(userId), clientId);
      refresh(userId);
    },
    [userId],
  );

  const retryNow = useCallback(() => flushTaps(userId, qc), [userId, qc]);

  return { ...snap, tap, undo, dismiss, retryNow };
}
