import { useCallback, useEffect, useMemo, useSyncExternalStore } from 'react';
import { useQueryClient, type QueryClient } from '@tanstack/react-query';
import { isSignedInAs } from '../../lib/authUser';
import { scopedKey, userStore } from '../../lib/scopedStore';
import { supabase } from '../../lib/supabase';
import { appErrorCode, isRetryable, toRpcError } from '../washroom/rpcError';
import {
  addBatch,
  dismissRejectedEstimate,
  flushOutbox,
  OUTBOX_KEY,
  readOutbox,
  readRejectedEstimates,
  REJECTED_ESTIMATES_KEY,
  updatePin,
  type OutboxApi,
  type OutboxBatch,
  type RecordOutcome,
  type RejectedEstimate,
  type SessionOutcome,
} from './estimateOutbox';
import {
  forgetSession,
  readSession,
  rememberSession,
  sessionEnd,
  validSession,
} from './sessionCache';

// Sends soil estimates through the device outbox (estimateOutbox.ts) and keeps the staff-session
// reuse cache (sessionCache.ts). Security H1: all of it lives in the signed-in account's own storage
// (plantboard.<userId>.…), a flush reads only that account's batches and runs only while that
// account is signed in. One flusher per account per tab.

const RETRY_EVERY_MS = 15_000;

export interface OpenedSession {
  sessionId: string;
  /** The server's expires_at when it returns one. */
  expiresAt: string | null;
}

/** start_staff_session, with the outcome shapes the outbox understands. */
export async function startSessionDetailed(
  staffId: string,
  pin: string,
): Promise<SessionOutcome & { expiresAt?: string | null }> {
  if (!/^\d{4}$/.test(pin)) return { kind: 'pin', error: 'PIN_NEEDED' };
  try {
    const res = await supabase.rpc('start_staff_session', { p_staff_id: staffId, p_pin: pin });
    if (res.error) {
      const e = toRpcError(res.error);
      return isRetryable(e)
        ? { kind: 'retry', error: e.code ?? 'NETWORK' }
        : { kind: 'rejected', errorCode: e.code ?? 'UNKNOWN' };
    }
    const r = res.data;
    if (r?.staff_session_id) {
      return { kind: 'ok', sessionId: r.staff_session_id, expiresAt: r.expires_at ?? null };
    }
    return { kind: 'pin', error: r?.error ?? 'PIN_INVALID' };
  } catch {
    return { kind: 'retry', error: 'NETWORK' };
  }
}

function apiFor(userId: string, onSession: (staffId: string, s: OpenedSession) => void): OutboxApi {
  return {
    // Re-review note 3: the account is checked before EVERY server call.
    shouldContinue: () => isSignedInAs(userId),
    async startSession(staffId, pin) {
      const s = await startSessionDetailed(staffId, pin);
      if (s.kind === 'ok')
        onSession(staffId, { sessionId: s.sessionId, expiresAt: s.expiresAt ?? null });
      return s;
    },
    async record(entry, sessionId): Promise<RecordOutcome> {
      try {
        const res = await supabase.rpc('record_soil_estimate', {
          p_wash_group_id: entry.washGroupId,
          p_qty: entry.qty,
          p_unit: entry.unit,
          p_client_id: entry.clientId,
          p_staff_session_id: sessionId,
          // The time the estimate was made, so one sent after an outage keeps its real time.
          ...(entry.enteredAt ? { p_entered_at: entry.enteredAt } : {}),
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

export interface OutboxSnapshot {
  pending: OutboxBatch[];
  rejected: RejectedEstimate[];
  /** Set when a waiting batch needs its PIN entered (wrong, changed, expired after 72 h). */
  needsPin: { staffId: string; error: string } | null;
}

interface UserState {
  snapshot: OutboxSnapshot;
  needsPin: OutboxSnapshot['needsPin'];
  flushing: Promise<number> | null;
}

const users = new Map<string, UserState>();
const listeners = new Set<() => void>();

function read(userId: string, needsPin: OutboxSnapshot['needsPin']): OutboxSnapshot {
  const store = userStore(userId);
  const pending = readOutbox(store);
  const stuck = pending.find((b) => !b.pin && !b.sessionId);
  return {
    pending,
    rejected: readRejectedEstimates(store),
    needsPin:
      needsPin ??
      (stuck ? { staffId: stuck.staffId, error: stuck.lastError ?? 'PIN_NEEDED' } : null),
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

/** Context a flush needs to keep the session cache right. */
export interface FlushContext {
  plantId: string;
  reuseMinutes: number;
  qc?: QueryClient;
}

/** Sends this account's waiting estimates (only while it is the signed-in account). */
export function flushEstimates(userId: string, ctx?: FlushContext): Promise<number> {
  const s = state(userId);
  if (s.flushing) return s.flushing;
  s.flushing = (async () => {
    try {
      if (!(await isSignedInAs(userId))) return 0;
      const store = userStore(userId);
      const api = apiFor(userId, (staffId, opened) => {
        if (!ctx) return;
        const end = sessionEnd(opened.expiresAt, Date.now(), ctx.reuseMinutes);
        if (end !== null) {
          rememberSession(store, {
            userId,
            plantId: ctx.plantId,
            staffId,
            sessionId: opened.sessionId,
            expiresAt: end,
          });
        }
      });
      const r = await flushOutbox(store, api);
      s.needsPin = r.needsPin;
      if (r.needsPin) forgetSession(store);
      if (ctx?.qc && (r.saved.length > 0 || r.rejected.length > 0)) {
        void ctx.qc.invalidateQueries({ queryKey: ['soil'] });
      }
      return r.saved.length;
    } finally {
      s.flushing = null;
      refresh(userId);
    }
  })();
  return s.flushing;
}

/** How many estimates this account has waiting (for the guarded sign-out). */
export function pendingEstimateCount(userId: string): number {
  return readOutbox(userStore(userId)).reduce((n, b) => n + b.entries.length, 0);
}

const LAST_STAFF_KEY = 'estimates.lastStaff.v1';

export function readLastStaff(userId: string): string {
  try {
    return userStore(userId).getItem(LAST_STAFF_KEY) ?? '';
  } catch {
    return '';
  }
}

export function useEstimateOutbox(userId: string, plantId: string, reuseMinutes: number) {
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
  const hasPending = snap.pending.length > 0;
  const ctx = useMemo(() => ({ plantId, reuseMinutes, qc }), [plantId, reuseMinutes, qc]);

  useEffect(() => {
    const run = () => void flushEstimates(userId, ctx);
    if (readOutbox(userStore(userId)).length > 0) run();
    window.addEventListener('online', run);
    const id = hasPending ? window.setInterval(run, RETRY_EVERY_MS) : undefined;
    return () => {
      window.removeEventListener('online', run);
      if (id !== undefined) window.clearInterval(id);
    };
  }, [userId, ctx, hasPending]);

  /** A still-valid session for this account, plant and person on this phone. */
  const cachedSession = useCallback(
    (staffId: string | null, nowMs: number) =>
      validSession(readSession(userStore(userId)), nowMs, { userId, plantId, staffId }),
    [userId, plantId],
  );

  /** Remembers a session the screen opened itself (PIN checked before saving). */
  const rememberNewSession = useCallback(
    (staffId: string, opened: OpenedSession) => {
      const end = sessionEnd(opened.expiresAt, Date.now(), reuseMinutes);
      if (end !== null) {
        rememberSession(userStore(userId), {
          userId,
          plantId,
          staffId,
          sessionId: opened.sessionId,
          expiresAt: end,
        });
      }
    },
    [userId, plantId, reuseMinutes],
  );

  /** Saves a batch to the device, then sends it. */
  const submit = useCallback(
    async (
      batch: OutboxBatch,
      lastStaffId: string,
    ): Promise<{ stored: boolean; saved: number }> => {
      const store = userStore(userId);
      const stored = addBatch(store, batch);
      try {
        store.setItem(LAST_STAFF_KEY, lastStaffId);
      } catch {
        // not remembered; asked again next time
      }
      refresh(userId);
      const saved = await flushEstimates(userId, ctx);
      return { stored, saved };
    },
    [userId, ctx],
  );

  /** The PIN was entered again for a stuck batch. */
  const retryWithPin = useCallback(
    async (staffId: string, pin: string) => {
      updatePin(userStore(userId), staffId, pin);
      state(userId).needsPin = null;
      refresh(userId);
      return flushEstimates(userId, ctx);
    },
    [userId, ctx],
  );

  const dismiss = useCallback(
    (clientId: string) => {
      dismissRejectedEstimate(userStore(userId), clientId);
      refresh(userId);
    },
    [userId],
  );

  return { ...snap, cachedSession, submit, rememberNewSession, retryWithPin, dismiss };
}
