// Outbox for customer deliveries (owner 2026-11-06 B), the same pattern as the estimates outbox
// (estimateOutbox.ts): a delivery is written to device storage BEFORE the first attempt, with its
// client_id, the entry person's id and PIN, and the staff session if one is open. The record, PIN
// included, is wiped as soon as the delivery is saved or refused; a refused delivery keeps no PIN.
// PINs are attribution only (A8); a stored PIN is wiped after 6 hours. Pure module: storage and the
// server calls are injected.

import type { KeyValueStore } from '../../lib/scopedStore';
import { ENTRY_MAX_AGE_MS, PIN_MAX_AGE_MS } from '../estimates/estimateOutbox';
import type { RecordOutcome, SessionOutcome } from '../estimates/estimateOutbox';
import type { DeliveryLine } from './deliveryMath';

export interface PendingDelivery {
  clientId: string;
  plantId: string;
  customerId: string;
  lines: DeliveryLine[];
  note: string | null;
  /** When it was entered (ISO); sent as p_entered_at when it waited on the phone. */
  enteredAt: string;
  staffId: string;
  pin: string;
  sessionId: string | null;
  createdAt: string;
  pinStoredAt?: string;
  lastError: string | null;
}

/** A refused delivery: what was entered and why, never the PIN or session. */
export interface RejectedDelivery {
  clientId: string;
  customerId: string;
  lines: DeliveryLine[];
  enteredAt: string;
  errorCode: string;
}

export const DELIVERY_OUTBOX_KEY = 'deliveries.outbox.v1';
export const REJECTED_DELIVERIES_KEY = 'deliveries.rejected.v1';

function isLine(v: unknown): v is DeliveryLine {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  return typeof o.washGroupId === 'string' && typeof o.bins === 'number';
}

function isPending(v: unknown): v is PendingDelivery {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  return (
    typeof o.clientId === 'string' &&
    typeof o.plantId === 'string' &&
    typeof o.customerId === 'string' &&
    Array.isArray(o.lines) &&
    o.lines.length > 0 &&
    o.lines.every(isLine) &&
    (o.note === null || typeof o.note === 'string') &&
    typeof o.enteredAt === 'string' &&
    typeof o.staffId === 'string' &&
    typeof o.pin === 'string' &&
    (o.sessionId === null || typeof o.sessionId === 'string') &&
    typeof o.createdAt === 'string' &&
    (o.pinStoredAt === undefined || typeof o.pinStoredAt === 'string')
  );
}

function isRejected(v: unknown): v is RejectedDelivery {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  return (
    typeof o.clientId === 'string' &&
    typeof o.customerId === 'string' &&
    Array.isArray(o.lines) &&
    o.lines.every(isLine) &&
    typeof o.enteredAt === 'string' &&
    typeof o.errorCode === 'string'
  );
}

function read<T>(store: KeyValueStore, key: string, guard: (v: unknown) => v is T): T[] {
  try {
    const raw = store.getItem(key);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter(guard) : [];
  } catch {
    return [];
  }
}

function write(store: KeyValueStore, key: string, value: readonly unknown[]): boolean {
  try {
    store.setItem(key, JSON.stringify(value));
    return true;
  } catch {
    return false;
  }
}

export function readPendingDeliveries(store: KeyValueStore): PendingDelivery[] {
  return read(store, DELIVERY_OUTBOX_KEY, isPending);
}

export function readRejectedDeliveries(store: KeyValueStore): RejectedDelivery[] {
  return read(store, REJECTED_DELIVERIES_KEY, isRejected);
}

function toRejected(d: PendingDelivery, errorCode: string): RejectedDelivery {
  return {
    clientId: d.clientId,
    customerId: d.customerId,
    lines: d.lines,
    enteredAt: d.enteredAt,
    errorCode,
  };
}

function addRejected(store: KeyValueStore, list: RejectedDelivery[]): void {
  if (list.length > 0)
    write(store, REJECTED_DELIVERIES_KEY, [...readRejectedDeliveries(store), ...list]);
}

export function dismissRejectedDelivery(store: KeyValueStore, clientId: string): void {
  write(
    store,
    REJECTED_DELIVERIES_KEY,
    readRejectedDeliveries(store).filter((r) => r.clientId !== clientId),
  );
}

/** Saves a delivery before any attempt. False = the device refused to store it. */
export function addPendingDelivery(store: KeyValueStore, d: PendingDelivery): boolean {
  const rest = readPendingDeliveries(store).filter((x) => x.clientId !== d.clientId);
  const stamped = d.pin && !d.pinStoredAt ? { ...d, pinStoredAt: d.createdAt } : d;
  return write(store, DELIVERY_OUTBOX_KEY, [...rest, stamped]);
}

function replace(store: KeyValueStore, clientId: string, d: PendingDelivery | null): void {
  const list = readPendingDeliveries(store);
  write(
    store,
    DELIVERY_OUTBOX_KEY,
    d ? list.map((x) => (x.clientId === clientId ? d : x)) : list.filter((x) => x.clientId !== clientId),
  );
}

/** The PIN was entered again for this person's waiting deliveries (restarts its 6-hour clock). */
export function updateDeliveryPin(
  store: KeyValueStore,
  staffId: string,
  pin: string,
  nowMs: number = Date.now(),
): void {
  const at = new Date(nowMs).toISOString();
  write(
    store,
    DELIVERY_OUTBOX_KEY,
    readPendingDeliveries(store).map((d) =>
      d.staffId === staffId ? { ...d, pin, pinStoredAt: at, sessionId: null, lastError: null } : d,
    ),
  );
}

export interface DeliverySweep {
  tooOld: number;
  pinsWiped: number;
}

/**
 * Housekeeping that never sends (before every flush and at app start): a delivery entered more than
 * 6 h ago can no longer be saved → refused list (OUT_OF_RANGE_TIMESTAMP); a PIN stored more than 6 h
 * ago is wiped and the delivery waits for the PIN.
 */
export function sweepDeliveries(store: KeyValueStore, nowMs: number = Date.now()): DeliverySweep {
  const age = (iso: string | undefined) => {
    const t = iso ? Date.parse(iso) : NaN;
    return Number.isNaN(t) ? Infinity : nowMs - t;
  };
  const report: DeliverySweep = { tooOld: 0, pinsWiped: 0 };
  const kept: PendingDelivery[] = [];
  const old: RejectedDelivery[] = [];
  for (const d of readPendingDeliveries(store)) {
    if (age(d.enteredAt) > ENTRY_MAX_AGE_MS) {
      old.push(toRejected(d, 'OUT_OF_RANGE_TIMESTAMP'));
      continue;
    }
    if (d.pin && age(d.pinStoredAt ?? d.createdAt) > PIN_MAX_AGE_MS) {
      kept.push({ ...d, pin: '', sessionId: null, lastError: 'PIN_EXPIRED' });
      report.pinsWiped += 1;
    } else kept.push(d);
  }
  report.tooOld = old.length;
  addRejected(store, old);
  if (report.tooOld > 0 || report.pinsWiped > 0) write(store, DELIVERY_OUTBOX_KEY, kept);
  return report;
}

export interface DeliveryApi {
  record(d: PendingDelivery, sessionId: string): Promise<RecordOutcome>;
  startSession(staffId: string, pin: string): Promise<SessionOutcome>;
  /** Checked before every server call; false stops the flush (signed out / other account). */
  shouldContinue?(): Promise<boolean>;
}

export interface DeliveryFlushReport {
  saved: PendingDelivery[];
  rejected: RejectedDelivery[];
  remaining: PendingDelivery[];
  needsPin: { staffId: string; error: string } | null;
}

/**
 * Sends every waiting delivery, oldest first. A missing or spent staff session is replaced by one
 * opened with the stored PIN; a refused PIN is dropped at once (5 misses lock the person out).
 * Storage is updated after every step, so nothing is lost or sent twice (client_id makes a resend
 * harmless anyway).
 */
export async function flushDeliveries(
  store: KeyValueStore,
  api: DeliveryApi,
  nowMs: number = Date.now(),
): Promise<DeliveryFlushReport> {
  const report: DeliveryFlushReport = { saved: [], rejected: [], remaining: [], needsPin: null };
  const swept = sweepDeliveries(store, nowMs);
  if (swept.tooOld > 0) report.rejected.push(...readRejectedDeliveries(store).slice(-swept.tooOld));
  const go = async () => !api.shouldContinue || (await api.shouldContinue());
  const reject = (d: PendingDelivery, code: string) => {
    const r = toRejected(d, code);
    addRejected(store, [r]);
    report.rejected.push(r);
    replace(store, d.clientId, null);
  };

  all: for (const initial of readPendingDeliveries(store)) {
    let d = { ...initial };
    let fresh = false;
    for (let attempt = 0; attempt < 3; attempt += 1) {
      if (!d.sessionId) {
        if (!d.pin) {
          report.needsPin = { staffId: d.staffId, error: d.lastError ?? 'PIN_NEEDED' };
          continue all;
        }
        if (!(await go())) break all;
        const s = await api.startSession(d.staffId, d.pin);
        if (s.kind === 'pin') {
          d = { ...d, pin: '', lastError: s.error };
          replace(store, d.clientId, d);
          report.needsPin = { staffId: d.staffId, error: s.error };
          continue all;
        }
        if (s.kind === 'retry') {
          replace(store, d.clientId, { ...d, lastError: s.error });
          break all;
        }
        if (s.kind === 'rejected') {
          reject(d, s.errorCode);
          continue all;
        }
        d = { ...d, sessionId: s.sessionId, lastError: null };
        fresh = true;
        replace(store, d.clientId, d);
      }
      if (!(await go())) break all;
      const r = await api.record(d, d.sessionId as string);
      if (r.kind === 'saved') {
        report.saved.push(d);
        replace(store, d.clientId, null);
        continue all;
      }
      if (r.kind === 'rejected') {
        reject(d, r.errorCode);
        continue all;
      }
      if (r.kind === 'session') {
        if (fresh) {
          reject(d, 'STAFF_SESSION_REQUIRED');
          continue all;
        }
        d = { ...d, sessionId: null };
        replace(store, d.clientId, d);
        continue;
      }
      replace(store, d.clientId, { ...d, lastError: r.error });
      break all;
    }
  }
  report.remaining = readPendingDeliveries(store);
  return report;
}
