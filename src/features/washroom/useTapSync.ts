import { useCallback, useEffect, useSyncExternalStore } from 'react';
import { useQueryClient, type QueryClient } from '@tanstack/react-query';
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
  type KeyValueStore,
  type PendingTap,
  type RejectedTap,
  type SendOutcome,
} from './tapQueue';

// Washer start-taps that never get lost (task brief + frontend rules: client_id generated before the
// first attempt; entries persist offline). One module-level flusher per tab; other tabs are picked up
// through the `storage` event, and the server's client_id idempotency makes a double send harmless.

export type WasherLoadResult = Database['public']['CompositeTypes']['washer_load_result'];

/** How long the station offers UNDO after a start (the server allows 30 minutes). */
export const UNDO_WINDOW_MS = 60_000;
const RETRY_EVERY_MS = 15_000;

/** localStorage, falling back to memory when the device refuses (private mode, quota). */
function browserStore(): { store: KeyValueStore; isPersistent: () => boolean } {
  const memory = new Map<string, string>();
  let persistent = true;
  return {
    isPersistent: () => persistent,
    store: {
      getItem(key) {
        if (!persistent) return memory.get(key) ?? null;
        try {
          return window.localStorage.getItem(key);
        } catch {
          persistent = false;
          return memory.get(key) ?? null;
        }
      },
      setItem(key, value) {
        memory.set(key, value);
        if (!persistent) return;
        try {
          window.localStorage.setItem(key, value);
        } catch {
          persistent = false;
        }
      },
    },
  };
}

const { store, isPersistent } = browserStore();

export interface TapSnapshot {
  pending: PendingTap[];
  rejected: RejectedTap[];
  /** Results of taps sent from this tab, by client_id (for UNDO and the "Started" message). */
  sent: Record<string, WasherLoadResult>;
  /** false = this device can't keep taps across a reload; the screen says so. */
  persistent: boolean;
}

let sent: Record<string, WasherLoadResult> = {};
let snapshot: TapSnapshot = { pending: [], rejected: [], sent, persistent: true };
let loaded = false;
const listeners = new Set<() => void>();

function refresh() {
  snapshot = {
    pending: readPending(store),
    rejected: readRejected(store),
    sent,
    persistent: isPersistent(),
  };
  for (const l of listeners) l();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  const onStorage = (e: StorageEvent) => {
    if (e.key === PENDING_KEY || e.key === REJECTED_KEY) refresh();
  };
  window.addEventListener('storage', onStorage);
  return () => {
    listeners.delete(listener);
    window.removeEventListener('storage', onStorage);
  };
}

function getSnapshot(): TapSnapshot {
  if (!loaded) {
    loaded = true;
    snapshot = {
      pending: readPending(store),
      rejected: readRejected(store),
      sent,
      persistent: isPersistent(),
    };
  }
  return snapshot;
}

async function sendTap(tap: PendingTap): Promise<SendOutcome<WasherLoadResult>> {
  try {
    const res = await supabase.rpc('start_washer_load', {
      p_machine_id: tap.machineId,
      p_client_id: tap.clientId,
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

function invalidateWashroom(qc: QueryClient) {
  void qc.invalidateQueries({ queryKey: ['washroom-board'] });
  void qc.invalidateQueries({ queryKey: ['queue'] });
}

let flushing: Promise<void> | null = null;

function flush(qc: QueryClient): Promise<void> {
  if (flushing) return flushing;
  flushing = (async () => {
    try {
      const r = await flushPending(store, sendTap);
      if (r.sent.length > 0) {
        sent = { ...sent };
        for (const s of r.sent) sent[s.tap.clientId] = s.result;
      }
      if (r.sent.length > 0 || r.rejected.length > 0) invalidateWashroom(qc);
    } finally {
      flushing = null;
      refresh();
    }
  })();
  return flushing;
}

export function useTapSync() {
  const qc = useQueryClient();
  const snap = useSyncExternalStore(subscribe, getSnapshot);
  const hasPending = snap.pending.length > 0;

  // Retry on mount, when the device comes back online, and every 15 s while anything is waiting.
  useEffect(() => {
    const run = () => void flush(qc);
    if (readPending(store).length > 0) run();
    window.addEventListener('online', run);
    const id = hasPending ? window.setInterval(run, RETRY_EVERY_MS) : undefined;
    return () => {
      window.removeEventListener('online', run);
      if (id !== undefined) window.clearInterval(id);
    };
  }, [qc, hasPending]);

  /** Records a start-tap on the device first, then sends it. Returns its client_id. */
  const tap = useCallback(
    (machineId: string, washGroupId: string | null): string => {
      const clientId = crypto.randomUUID();
      addPending(store, newTap(machineId, washGroupId, clientId, new Date()));
      refresh();
      void flush(qc);
      return clientId;
    },
    [qc],
  );

  /**
   * Undo a start. Not sent yet → removed from the device (it never reaches the server). Sent → the
   * server voids the cycle. Throws an RpcError if the server refuses or can't be reached.
   */
  const undo = useCallback(
    async (clientId: string): Promise<void> => {
      if (removePending(store, clientId)) {
        refresh();
        return;
      }
      const result = sent[clientId];
      if (!result?.cycle_id) return;
      unwrap(await supabase.rpc('undo_washer_load', { p_cycle_id: result.cycle_id }));
      sent = Object.fromEntries(Object.entries(sent).filter(([k]) => k !== clientId));
      refresh();
      invalidateWashroom(qc);
    },
    [qc],
  );

  const dismiss = useCallback((clientId: string) => {
    dismissRejected(store, clientId);
    refresh();
  }, []);

  const retryNow = useCallback(() => flush(qc), [qc]);

  return { ...snap, tap, undo, dismiss, retryNow };
}
