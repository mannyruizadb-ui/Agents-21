import { useCallback, useEffect, useMemo, useSyncExternalStore } from 'react';
import { useQueryClient, type QueryClient } from '@tanstack/react-query';
import { isSignedInAs } from '../../lib/authUser';
import { scopedKey, userStore } from '../../lib/scopedStore';
import { supabase } from '../../lib/supabase';
import { appErrorCode, isRetryable } from '../washroom/rpcError';
import type { RecordOutcome } from '../estimates/estimateOutbox';
import { rememberSession, sessionEnd } from '../estimates/sessionCache';
import { startSessionDetailed } from '../estimates/useEstimateOutbox';
import { enteredAtParam } from './deliveryMath';
import {
  addPendingDelivery,
  DELIVERY_OUTBOX_KEY,
  dismissRejectedDelivery,
  flushDeliveries as flushStore,
  readPendingDeliveries,
  readRejectedDeliveries,
  REJECTED_DELIVERIES_KEY,
  updateDeliveryPin,
  type DeliveryApi,
  type PendingDelivery,
  type RejectedDelivery,
} from './deliveryOutbox';

// Sends customer deliveries through the device outbox (deliveryOutbox.ts), in the signed-in
// account's own storage (security H1), only while that account is signed in. Staff sessions opened
// here go into the same 10-minute reuse cache the estimates screen uses (one PIN for both).

const RETRY_EVERY_MS = 15_000;

function apiFor(userId: string, onSession: (staffId: string, id: string, exp: string | null) => void): DeliveryApi {
  return {
    shouldContinue: () => isSignedInAs(userId),
    async startSession(staffId, pin) {
      const s = await startSessionDetailed(staffId, pin);
      if (s.kind === 'ok') onSession(staffId, s.sessionId, s.expiresAt ?? null);
      return s;
    },
    async record(d, sessionId): Promise<RecordOutcome> {
      try {
        const at = enteredAtParam(d.enteredAt, Date.now());
        const res = await supabase.rpc('record_customer_delivery', {
          p_plant_id: d.plantId,
          p_customer_id: d.customerId,
          p_lines: d.lines.map((l) => ({ wash_group_id: l.washGroupId, bins: l.bins })),
          p_client_id: d.clientId,
          p_staff_session_id: sessionId,
          ...(d.note ? { p_note: d.note } : {}),
          ...(at ? { p_entered_at: at } : {}),
        });
        if (!res.error) return { kind: 'saved' };
        const code = appErrorCode(res.error);
        if (code === 'STAFF_SESSION_REQUIRED') return { kind: 'session' };
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
  needsPin: { staffId: string; error: string } | null;
}

interface UserState {
  snapshot: DeliverySnapshot;
  needsPin: DeliverySnapshot['needsPin'];
  flushing: Promise<number> | null;
}

const users = new Map<string, UserState>();
const listeners = new Set<() => void>();

function read(userId: string, needsPin: DeliverySnapshot['needsPin']): DeliverySnapshot {
  const store = userStore(userId);
  const pending = readPendingDeliveries(store);
  const stuck = pending.find((d) => !d.pin && !d.sessionId);
  return {
    pending,
    rejected: readRejectedDeliveries(store),
    needsPin:
      needsPin ?? (stuck ? { staffId: stuck.staffId, error: stuck.lastError ?? 'PIN_NEEDED' } : null),
  };
}

function state(userId: string): UserState {
  let s = users.get(userId);
  if (!s) {
    s = { needsPin: null, flushing: null, snapshot: read(userId, null) };
    users.set(userId, s);
  }
  return s;
}

function refresh(userId: string) {
  const s = state(userId);
  s.snapshot = read(userId, s.needsPin);
  for (const l of listeners) l();
}

export interface DeliveryFlushContext {
  reuseMinutes: number;
  qc?: QueryClient;
}

/** Sends this account's waiting deliveries (only while it is the signed-in account). */
export function flushDeliveries(userId: string, ctx?: DeliveryFlushContext): Promise<number> {
  const s = state(userId);
  if (s.flushing) return s.flushing;
  s.flushing = (async () => {
    try {
      if (!(await isSignedInAs(userId))) return 0;
      const store = userStore(userId);
      const plantOf = new Map(readPendingDeliveries(store).map((d) => [d.staffId, d.plantId]));
      const api = apiFor(userId, (staffId, sessionId, exp) => {
        const plantId = plantOf.get(staffId);
        if (!ctx || !plantId) return;
        const end = sessionEnd(exp, Date.now(), ctx.reuseMinutes);
        if (end !== null) rememberSession(store, { userId, plantId, staffId, sessionId, expiresAt: end });
      });
      const r = await flushStore(store, api);
      s.needsPin = r.needsPin;
      if (ctx?.qc && r.saved.length > 0) {
        void ctx.qc.invalidateQueries({ queryKey: ['queue'] });
        void ctx.qc.invalidateQueries({ queryKey: ['customer-deliveries'] });
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

export function useDeliveryOutbox(userId: string, reuseMinutes: number) {
  const qc = useQueryClient();
  const subscribe = useMemo(
    () => (l: () => void) => {
      listeners.add(l);
      const onStorage = (e: StorageEvent) => {
        if (
          e.key === scopedKey(userId, DELIVERY_OUTBOX_KEY) ||
          e.key === scopedKey(userId, REJECTED_DELIVERIES_KEY)
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
  const hasPending = snap.pending.length > 0;
  const ctx = useMemo(() => ({ reuseMinutes, qc }), [reuseMinutes, qc]);

  useEffect(() => {
    const run = () => void flushDeliveries(userId, ctx);
    if (readPendingDeliveries(userStore(userId)).length > 0) run();
    window.addEventListener('online', run);
    const id = hasPending ? window.setInterval(run, RETRY_EVERY_MS) : undefined;
    return () => {
      window.removeEventListener('online', run);
      if (id !== undefined) window.clearInterval(id);
    };
  }, [userId, ctx, hasPending]);

  /** Stores the delivery on the device, then sends it. */
  const submit = useCallback(
    async (d: PendingDelivery): Promise<{ stored: boolean; saved: boolean }> => {
      const stored = addPendingDelivery(userStore(userId), d);
      refresh(userId);
      await flushDeliveries(userId, ctx);
      const still = readPendingDeliveries(userStore(userId)).some((x) => x.clientId === d.clientId);
      const refused = readRejectedDeliveries(userStore(userId)).some(
        (x) => x.clientId === d.clientId,
      );
      return { stored, saved: stored && !still && !refused };
    },
    [userId, ctx],
  );

  const retryWithPin = useCallback(
    async (staffId: string, pin: string) => {
      updateDeliveryPin(userStore(userId), staffId, pin);
      state(userId).needsPin = null;
      refresh(userId);
      return flushDeliveries(userId, ctx);
    },
    [userId, ctx],
  );

  const dismiss = useCallback(
    (clientId: string) => {
      dismissRejectedDelivery(userStore(userId), clientId);
      refresh(userId);
    },
    [userId],
  );

  return { ...snap, submit, retryWithPin, dismiss };
}
