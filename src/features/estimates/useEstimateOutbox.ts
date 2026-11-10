import { useCallback, useMemo, useSyncExternalStore } from 'react';
import { useQueryClient, type QueryClient } from '@tanstack/react-query';
import { isSignedInAs } from '../../lib/authUser';
import { scopedKey, userStore } from '../../lib/scopedStore';
import { supabase } from '../../lib/supabase';
import { appErrorCode, isRetryable } from '../washroom/rpcError';
import {
  addBatch,
  batchSavedCount,
  dismissRejectedEstimate,
  flushOutbox,
  OUTBOX_KEY,
  readOutbox,
  readRejectedEstimates,
  REJECTED_ESTIMATES_KEY,
  type OutboxApi,
  type OutboxBatch,
  type RecordOutcome,
  type RejectedEstimate,
} from './estimateOutbox';

// Sends soil estimates through the device outbox (estimateOutbox.ts). Security H1: it lives in the
// signed-in account's own storage (plantboard.<userId>.…), a flush reads only that account's batches
// and runs only while that account is signed in. One flusher per account per tab.
// 2026-11-07: no entry PIN; the signed-in account is the attribution (record_soil_estimate).
// Retries (mount, `online`, every 15 s) run app-wide in OutboxRunner (src/app/control), not here, so
// estimates saved offline send whichever screen is open.

function apiFor(userId: string): OutboxApi {
  return {
    // Re-review note 3: the account is checked before EVERY server call.
    shouldContinue: () => isSignedInAs(userId),
    async record(entry): Promise<RecordOutcome> {
      try {
        const res = await supabase.rpc('record_soil_estimate', {
          p_wash_group_id: entry.washGroupId,
          p_qty: entry.qty,
          p_unit: entry.unit,
          p_client_id: entry.clientId,
          // The time the estimate was made, so one sent after an outage keeps its real time.
          ...(entry.enteredAt ? { p_entered_at: entry.enteredAt } : {}),
        });
        if (!res.error) return { kind: 'saved' };
        const code = appErrorCode(res.error);
        return isRetryable(res.error)
          ? { kind: 'retry', error: code ?? 'NETWORK' }
          : { kind: 'rejected', errorCode: code ?? 'UNKNOWN' };
      } catch {
        return { kind: 'retry', error: 'NETWORK' };
      }
    },
  };
}

export interface OutboxSnapshot {
  pending: OutboxBatch[];
  rejected: RejectedEstimate[];
}

interface UserState {
  snapshot: OutboxSnapshot;
  flushing: Promise<number> | null;
}

const users = new Map<string, UserState>();
const listeners = new Set<() => void>();

function read(userId: string): OutboxSnapshot {
  const store = userStore(userId);
  return { pending: readOutbox(store), rejected: readRejectedEstimates(store) };
}

function state(userId: string): UserState {
  let s = users.get(userId);
  if (!s) {
    s = { flushing: null, snapshot: read(userId) };
    users.set(userId, s);
  }
  return s;
}

function refresh(userId: string) {
  state(userId).snapshot = read(userId);
  for (const l of listeners) l();
}

/** Sends this account's waiting estimates (only while it is the signed-in account). */
export function flushEstimates(userId: string, qc?: QueryClient): Promise<number> {
  const s = state(userId);
  if (s.flushing) return s.flushing;
  s.flushing = (async () => {
    try {
      if (!(await isSignedInAs(userId))) return 0;
      const r = await flushOutbox(userStore(userId), apiFor(userId));
      if (qc && (r.saved.length > 0 || r.rejected.length > 0)) {
        void qc.invalidateQueries({ queryKey: ['soil'] });
        // Owner 2026-11-09: a saved estimate also creates/updates its queue item on the server.
        void qc.invalidateQueries({ queryKey: ['queue'] });
        void qc.invalidateQueries({ queryKey: ['washroom-board'] });
      }
      return r.saved.length;
    } finally {
      s.flushing = null;
      refresh(userId);
    }
  })();
  return s.flushing;
}

/** Resolves once no flush is running for this account (one started meanwhile is waited for too). */
async function waitForFlush(userId: string): Promise<void> {
  const s = state(userId);
  while (s.flushing) await s.flushing;
}

/** How many estimates this account has waiting (for the guarded sign-out). */
export function pendingEstimateCount(userId: string): number {
  return readOutbox(userStore(userId)).reduce((n, b) => n + b.entries.length, 0);
}

export function useEstimateOutbox(userId: string) {
  const qc = useQueryClient();
  const subscribe = useMemo(
    () => (l: () => void) => {
      listeners.add(l);
      const onStorage = (e: StorageEvent) => {
        if (
          e.key === scopedKey(userId, OUTBOX_KEY) ||
          e.key === scopedKey(userId, REJECTED_ESTIMATES_KEY)
        ) {
          refresh(userId);
        }
      };
      window.addEventListener('storage', onStorage);
      return () => {
        listeners.delete(l);
        window.removeEventListener('storage', onStorage);
      };
    },
    [userId],
  );
  const getSnapshot = useCallback(() => state(userId).snapshot, [userId]);
  const snap = useSyncExternalStore(subscribe, getSnapshot);

  /** Saves a batch to the device, then sends it. */
  const submit = useCallback(
    async (batch: OutboxBatch): Promise<{ stored: boolean; saved: number }> => {
      const store = userStore(userId);
      const stored = addBatch(store, batch);
      refresh(userId);
      // An older flush may be on the wire (started before this batch was stored): its count is not
      // this batch's. Wait for it, run a fresh one, then count THIS batch's entries that left.
      await waitForFlush(userId);
      await flushEstimates(userId, qc);
      const saved = stored
        ? batchSavedCount(batch, readOutbox(store), readRejectedEstimates(store))
        : 0;
      return { stored, saved };
    },
    [userId, qc],
  );

  const dismiss = useCallback(
    (clientId: string) => {
      dismissRejectedEstimate(userStore(userId), clientId);
      refresh(userId);
    },
    [userId],
  );

  return { ...snap, submit, dismiss };
}
