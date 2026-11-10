import { useCallback, useMemo, useSyncExternalStore } from 'react';
import { useQueryClient, type QueryClient } from '@tanstack/react-query';
import { isSignedInAs } from '../../lib/authUser';
import { scopedKey, userStore } from '../../lib/scopedStore';
import { supabase } from '../../lib/supabase';
import { appErrorCode, isRetryable } from '../washroom/rpcError';
import {
  addPendingFinished,
  dismissRejectedFinished,
  FINISHED_OUTBOX_KEY,
  flushFinished as flushStore,
  markSavedVoided,
  readPendingFinished,
  readRejectedFinished,
  readSavedFinished,
  REJECTED_FINISHED_KEY,
  removePendingFinished,
  SAVED_FINISHED_KEY,
  type FinishedApi,
  type FinishedRecordOutcome,
  type PendingFinished,
  type RejectedFinished,
  type SavedFinished,
} from './finishedOutbox';
import { finishedKeys } from './finishedData';
import { enteredAtParam } from '../deliveries/deliveryMath';

// Sends finished-goods entries through the device outbox (finishedOutbox.ts), in the signed-in
// account's own storage (security H1), only while that account is signed in. Retries (mount, `online`,
// every 15 s) run app-wide in OutboxRunner (src/app/control), so lines saved offline send whichever
// screen is open. One flush per account per tab.

/** Undo / void reasons sent to void_finished_goods (stable words, never shown raw). */
export type VoidReason = 'undo' | 'wrong_item' | 'wrong_number' | 'duplicate';

function apiFor(userId: string): FinishedApi {
  return {
    shouldContinue: () => isSignedInAs(userId),
    async record(d): Promise<FinishedRecordOutcome> {
      try {
        const at = enteredAtParam(d.enteredAt, Date.now());
        const res = await supabase.rpc('record_finished_goods', {
          p_item_type_id: d.itemTypeId,
          p_packs: d.packs,
          p_loose_pieces: d.loose,
          p_client_id: d.clientId,
          p_area_id: d.areaId,
          // A line that waited on the device keeps the time it was entered (so it keeps its shift);
          // a fresh one uses the server's clock (a fast device clock is never refused).
          ...(at ? { p_occurred_at: at } : {}),
          ...(d.packSizeUsed !== null ? { p_pack_size_used: d.packSizeUsed } : {}),
        });
        if (!res.error) {
          return {
            kind: 'saved',
            id: res.data?.id ?? null,
            pieces: res.data?.pieces ?? null,
            occurredAt: res.data?.occurred_at ?? null,
          };
        }
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

export interface FinishedSnapshot {
  pending: PendingFinished[];
  rejected: RejectedFinished[];
  saved: SavedFinished[];
}

interface UserState {
  snapshot: FinishedSnapshot;
  flushing: Promise<number> | null;
}

const users = new Map<string, UserState>();
const listeners = new Set<() => void>();

function read(userId: string): FinishedSnapshot {
  const store = userStore(userId);
  return {
    pending: readPendingFinished(store),
    rejected: readRejectedFinished(store),
    saved: readSavedFinished(store),
  };
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

async function waitForFlush(userId: string): Promise<void> {
  const s = state(userId);
  while (s.flushing) await s.flushing;
}

/** Sends this account's waiting finished-goods lines (only while it is the signed-in account). */
export function flushFinished(userId: string, qc?: QueryClient): Promise<number> {
  const s = state(userId);
  if (s.flushing) return s.flushing;
  s.flushing = (async () => {
    try {
      if (!(await isSignedInAs(userId))) return 0;
      const r = await flushStore(userStore(userId), apiFor(userId));
      if (qc && (r.saved.length > 0 || r.rejected.length > 0)) {
        void qc.invalidateQueries({ queryKey: finishedKeys.all });
      }
      return r.saved.length;
    } finally {
      s.flushing = null;
      refresh(userId);
    }
  })();
  return s.flushing;
}

/** How many lines this account has waiting (for the guarded sign-out). */
export function pendingFinishedCount(userId: string): number {
  return readPendingFinished(userStore(userId)).length;
}

export type SubmitResult =
  | { kind: 'saved' }
  | { kind: 'waiting' } // stored on the device, will send
  | { kind: 'rejected'; errorCode: string }
  | { kind: 'notStored' };

export type UndoResult = 'removed' | 'voided' | 'failed';

export function useFinishedOutbox(userId: string) {
  const qc = useQueryClient();
  const subscribe = useMemo(
    () => (l: () => void) => {
      listeners.add(l);
      const keys = [FINISHED_OUTBOX_KEY, REJECTED_FINISHED_KEY, SAVED_FINISHED_KEY].map((k) =>
        scopedKey(userId, k),
      );
      const onStorage = (e: StorageEvent) => {
        if (e.key && keys.includes(e.key)) refresh(userId);
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

  /** Stores the line on the device (before any attempt), then sends it. */
  const submit = useCallback(
    async (d: PendingFinished): Promise<SubmitResult> => {
      const store = userStore(userId);
      if (!addPendingFinished(store, d)) {
        refresh(userId);
        return { kind: 'notStored' };
      }
      refresh(userId);
      await waitForFlush(userId);
      await flushFinished(userId, qc);
      if (readPendingFinished(store).some((x) => x.clientId === d.clientId))
        return { kind: 'waiting' };
      const refused = readRejectedFinished(store).find((x) => x.clientId === d.clientId);
      return refused ? { kind: 'rejected', errorCode: refused.errorCode } : { kind: 'saved' };
    },
    [userId, qc],
  );

  /** Voids a saved line (server) with a reason; marks it voided on this device. */
  const voidLine = useCallback(
    async (id: string, reason: VoidReason): Promise<boolean> => {
      try {
        const res = await supabase.rpc('void_finished_goods', { p_id: id, p_reason: reason });
        if (res.error) return false;
        markSavedVoided(userStore(userId), id, res.data?.voided_at ?? new Date().toISOString());
        return true;
      } catch {
        return false; // network: the line stays; the person can try again
      } finally {
        refresh(userId);
        void qc.invalidateQueries({ queryKey: finishedKeys.all });
      }
    },
    [userId, qc],
  );

  /**
   * Undo a line by its client_id: still on the device → taken off (never sent); already sent → voided
   * on the server with reason 'undo'. Waits for a send in progress first, so the line is never sent
   * after it was taken off.
   */
  const undo = useCallback(
    async (clientId: string): Promise<UndoResult> => {
      await waitForFlush(userId);
      const store = userStore(userId);
      // No await between the check and the removal: a flush cannot start in between.
      if (removePendingFinished(store, clientId)) {
        refresh(userId);
        return 'removed';
      }
      const saved = readSavedFinished(store).find((x) => x.clientId === clientId);
      if (!saved) return 'failed';
      if (saved.voidedAt) return 'voided';
      return (await voidLine(saved.id, 'undo')) ? 'voided' : 'failed';
    },
    [userId, voidLine],
  );

  const dismiss = useCallback(
    (clientId: string) => {
      dismissRejectedFinished(userStore(userId), clientId);
      refresh(userId);
    },
    [userId],
  );

  return { ...snap, submit, undo, voidLine, dismiss };
}
