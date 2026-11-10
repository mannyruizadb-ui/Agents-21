import { useCallback, useMemo, useSyncExternalStore } from 'react';
import { useQueryClient, type QueryClient } from '@tanstack/react-query';
import { isSignedInAs } from '../../lib/authUser';
import { scopedKey, userStore } from '../../lib/scopedStore';
import { supabase } from '../../lib/supabase';
import { appErrorCode, isRetryable } from '../washroom/rpcError';
import { enteredAtParam } from './deliveryMath';
import {
  addPendingDelivery,
  DELIVERY_OUTBOX_KEY,
  dismissRejectedDelivery,
  flushDeliveries as flushStore,
  markRecentVoided,
  readPendingDeliveries,
  readRecentDeliveries,
  readRejectedDeliveries,
  RECENT_DELIVERIES_KEY,
  REJECTED_DELIVERIES_KEY,
  type DeliveryApi,
  type DeliveryRecordOutcome,
  type PendingDelivery,
  type RecentDelivery,
  type RejectedDelivery,
} from './deliveryOutbox';

// Sends customer deliveries through the device outbox (deliveryOutbox.ts), in the signed-in
// account's own storage (security H1), only while that account is signed in. 2026-11-07: no entry
// PIN; the signed-in account is the attribution. Saved deliveries are remembered (recent list) so
// they can be cancelled from this phone. Retries (mount, `online`, every 15 s) run app-wide in
// OutboxRunner (src/app/control), not here, so drop-offs saved offline send whichever screen is open.

function apiFor(userId: string): DeliveryApi {
  return {
    shouldContinue: () => isSignedInAs(userId),
    async record(d): Promise<DeliveryRecordOutcome> {
      try {
        const at = enteredAtParam(d.enteredAt, Date.now());
        const res = await supabase.rpc('record_customer_delivery', {
          p_plant_id: d.plantId,
          p_customer_id: d.customerId,
          p_lines: d.lines.map((l) => ({ wash_group_id: l.washGroupId, bins: l.bins })),
          p_client_id: d.clientId,
          ...(d.note ? { p_note: d.note } : {}),
          ...(at ? { p_entered_at: at } : {}),
        });
        if (!res.error) {
          return {
            kind: 'saved',
            deliveryId: res.data?.delivery_id ?? null,
            queueItemIds: res.data?.queue_item_ids ?? [],
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

export interface DeliverySnapshot {
  pending: PendingDelivery[];
  rejected: RejectedDelivery[];
  recent: RecentDelivery[];
}

interface UserState {
  snapshot: DeliverySnapshot;
  flushing: Promise<number> | null;
}

const users = new Map<string, UserState>();
const listeners = new Set<() => void>();

function read(userId: string): DeliverySnapshot {
  const store = userStore(userId);
  return {
    pending: readPendingDeliveries(store),
    rejected: readRejectedDeliveries(store),
    recent: readRecentDeliveries(store),
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

/** Sends this account's waiting deliveries (only while it is the signed-in account). */
export function flushDeliveries(userId: string, qc?: QueryClient): Promise<number> {
  const s = state(userId);
  if (s.flushing) return s.flushing;
  s.flushing = (async () => {
    try {
      if (!(await isSignedInAs(userId))) return 0;
      const r = await flushStore(userStore(userId), apiFor(userId));
      if (qc && r.saved.length > 0) {
        void qc.invalidateQueries({ queryKey: ['queue'] });
        void qc.invalidateQueries({ queryKey: ['customer-deliveries'] });
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

/** How many deliveries this account has waiting (for the guarded sign-out). */
export function pendingDeliveryCount(userId: string): number {
  return readPendingDeliveries(userStore(userId)).length;
}

export function useDeliveryOutbox(userId: string) {
  const qc = useQueryClient();
  const subscribe = useMemo(
    () => (l: () => void) => {
      listeners.add(l);
      const onStorage = (e: StorageEvent) => {
        if (
          e.key === scopedKey(userId, DELIVERY_OUTBOX_KEY) ||
          e.key === scopedKey(userId, REJECTED_DELIVERIES_KEY) ||
          e.key === scopedKey(userId, RECENT_DELIVERIES_KEY)
        )
          refresh(userId);
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
  /** Stores the delivery on the device, then sends it. */
  const submit = useCallback(
    async (d: PendingDelivery): Promise<{ stored: boolean; saved: boolean }> => {
      const stored = addPendingDelivery(userStore(userId), d);
      refresh(userId);
      // A flush already on the wire may have read the list before this delivery was stored: wait
      // for it, then run a fresh one, so the answer is about THIS delivery.
      const s = state(userId);
      while (s.flushing) await s.flushing;
      await flushDeliveries(userId, qc);
      const still = readPendingDeliveries(userStore(userId)).some((x) => x.clientId === d.clientId);
      const refused = readRejectedDeliveries(userStore(userId)).some(
        (x) => x.clientId === d.clientId,
      );
      return { stored, saved: stored && !still && !refused };
    },
    [userId, qc],
  );

  /** Marks a delivery saved from this phone as cancelled (after void_customer_delivery). */
  const markVoided = useCallback(
    (deliveryId: string, voidedAt: string) => {
      markRecentVoided(userStore(userId), deliveryId, voidedAt);
      refresh(userId);
    },
    [userId],
  );

  const dismiss = useCallback(
    (clientId: string) => {
      dismissRejectedDelivery(userStore(userId), clientId);
      refresh(userId);
    },
    [userId],
  );

  return { ...snap, submit, dismiss, markVoided };
}
