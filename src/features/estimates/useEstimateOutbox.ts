import { useCallback, useEffect, useSyncExternalStore } from 'react';
import { useQueryClient, type QueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { appErrorCode, isRetryable, toRpcError } from '../washroom/rpcError';
import type { KeyValueStore } from '../washroom/tapQueue';
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
import { forgetSession, readSession, rememberSession, validSession } from './sessionCache';

// Sends soil estimates through the device outbox (estimateOutbox.ts) and keeps the staff-session
// reuse cache (sessionCache.ts). One module-level flusher per tab.

const RETRY_EVERY_MS = 15_000;

function localStore(): KeyValueStore {
  const memory = new Map<string, string>();
  return {
    getItem(k) {
      try {
        return window.localStorage.getItem(k);
      } catch {
        return memory.get(k) ?? null;
      }
    },
    setItem(k, v) {
      memory.set(k, v);
      try {
        window.localStorage.setItem(k, v);
      } catch {
        // falls back to memory for this page's life
      }
    },
  };
}

const store = localStore();

export async function startSession(staffId: string, pin: string): Promise<SessionOutcome> {
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
    if (r?.staff_session_id) return { kind: 'ok', sessionId: r.staff_session_id };
    return { kind: 'pin', error: r?.error ?? 'PIN_INVALID' };
  } catch {
    return { kind: 'retry', error: 'NETWORK' };
  }
}

const api: OutboxApi = {
  startSession,
  async record(entry, sessionId): Promise<RecordOutcome> {
    try {
      const res = await supabase.rpc('record_soil_estimate', {
        p_wash_group_id: entry.washGroupId,
        p_qty: entry.qty,
        p_unit: entry.unit,
        p_client_id: entry.clientId,
        p_staff_session_id: sessionId,
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

export interface OutboxSnapshot {
  pending: OutboxBatch[];
  rejected: RejectedEstimate[];
  /** Set when a waiting batch needs its PIN entered again. */
  needsPin: { staffId: string; error: string } | null;
}

let snapshot: OutboxSnapshot = { pending: [], rejected: [], needsPin: null };
let loaded = false;
let needsPin: OutboxSnapshot['needsPin'] = null;
const listeners = new Set<() => void>();

function refresh() {
  snapshot = { pending: readOutbox(store), rejected: readRejectedEstimates(store), needsPin };
  for (const l of listeners) l();
}

function subscribe(l: () => void) {
  listeners.add(l);
  const onStorage = (e: StorageEvent) => {
    if (e.key === OUTBOX_KEY || e.key === REJECTED_ESTIMATES_KEY) refresh();
  };
  window.addEventListener('storage', onStorage);
  return () => {
    listeners.delete(l);
    window.removeEventListener('storage', onStorage);
  };
}

function getSnapshot() {
  if (!loaded) {
    loaded = true;
    snapshot = { pending: readOutbox(store), rejected: readRejectedEstimates(store), needsPin };
  }
  return snapshot;
}

let flushing: Promise<number> | null = null;

/** Sends what is waiting. Resolves to the number of estimates saved. */
function flush(qc: QueryClient, reuseMinutes: number): Promise<number> {
  if (flushing) return flushing;
  flushing = (async () => {
    try {
      const before = readSession(store);
      const r = await flushOutbox(store, api);
      needsPin = r.needsPin;
      for (const s of r.sessions) {
        // Keep the original window end for a reused session; a new one starts its own window.
        if (before?.sessionId !== s.sessionId) {
          rememberSession(store, s.staffId, s.sessionId, Date.now(), reuseMinutes);
        }
      }
      if (r.needsPin) forgetSession(store);
      if (r.saved.length > 0 || r.rejected.length > 0) {
        void qc.invalidateQueries({ queryKey: ['soil'] });
      }
      return r.saved.length;
    } finally {
      flushing = null;
      refresh();
    }
  })();
  return flushing;
}

export function useEstimateOutbox(reuseMinutes: number) {
  const qc = useQueryClient();
  const snap = useSyncExternalStore(subscribe, getSnapshot);
  const hasPending = snap.pending.length > 0;

  useEffect(() => {
    const run = () => void flush(qc, reuseMinutes);
    if (readOutbox(store).length > 0) run();
    window.addEventListener('online', run);
    const id = hasPending ? window.setInterval(run, RETRY_EVERY_MS) : undefined;
    return () => {
      window.removeEventListener('online', run);
      if (id !== undefined) window.clearInterval(id);
    };
  }, [qc, hasPending, reuseMinutes]);

  /** A still-valid session for this person on this phone (the server's reuse window). */
  const cachedSession = useCallback(
    (staffId: string | null, nowMs: number) => validSession(readSession(store), nowMs, staffId),
    [],
  );

  /**
   * Saves a batch to the device, then sends it. `pin` may be '' when a cached session is used; if
   * that session turns out to be gone, the screen asks for the PIN (needsPin).
   */
  const submit = useCallback(
    async (batch: OutboxBatch): Promise<{ stored: boolean; saved: number }> => {
      const stored = addBatch(store, batch);
      refresh();
      const saved = await flush(qc, reuseMinutes);
      return { stored, saved };
    },
    [qc, reuseMinutes],
  );

  const rememberNewSession = useCallback(
    (staffId: string, sessionId: string) =>
      rememberSession(store, staffId, sessionId, Date.now(), reuseMinutes),
    [reuseMinutes],
  );

  /** The PIN was entered again for a stuck batch. */
  const retryWithPin = useCallback(
    async (staffId: string, pin: string) => {
      updatePin(store, staffId, pin);
      needsPin = null;
      refresh();
      return flush(qc, reuseMinutes);
    },
    [qc, reuseMinutes],
  );

  const dismiss = useCallback((clientId: string) => {
    dismissRejectedEstimate(store, clientId);
    refresh();
  }, []);

  return { ...snap, cachedSession, submit, rememberNewSession, retryWithPin, dismiss };
}
