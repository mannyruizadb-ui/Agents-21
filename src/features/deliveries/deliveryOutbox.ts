// Outbox for customer deliveries (owner 2026-11-06 B), the same pattern as the estimates outbox
// (estimateOutbox.ts): a delivery is written to device storage BEFORE the first attempt, with its
// client_id, and removed as soon as it is saved or refused. 2026-11-07 (one sign-in method): no entry
// PIN; the signed-in account is the attribution. Deliveries stored by an older version with a staff
// id / PIN / session are read without them and rewritten at the next sweep (the PIN is wiped).
// Saved deliveries are remembered for a while (recent list), so the person who recorded one on this
// phone can cancel it (void_customer_delivery) without the owner-only history.
// Pure module: storage and the server calls are injected.

import type { KeyValueStore } from '../../lib/scopedStore';
import { ENTRY_MAX_AGE_MS } from '../estimates/estimateOutbox';
import type { DeliveryLine } from './deliveryMath';

export interface PendingDelivery {
  clientId: string;
  plantId: string;
  customerId: string;
  lines: DeliveryLine[];
  note: string | null;
  /** When it was entered (ISO); sent as p_entered_at when it waited on the phone. */
  enteredAt: string;
  createdAt: string;
  lastError: string | null;
}

/** A refused delivery: what was entered and why. */
export interface RejectedDelivery {
  clientId: string;
  customerId: string;
  lines: DeliveryLine[];
  enteredAt: string;
  errorCode: string;
}

/** A delivery saved from this phone (for "Cancel this delivery"). */
export interface RecentDelivery {
  deliveryId: string;
  clientId: string;
  plantId: string;
  customerId: string;
  lines: DeliveryLine[];
  /** Queue item ids in line order (record_customer_delivery). */
  queueItemIds: string[];
  savedAt: string;
  /** Set once it was cancelled from this phone. */
  voidedAt?: string;
}

export const DELIVERY_OUTBOX_KEY = 'deliveries.outbox.v1';
export const REJECTED_DELIVERIES_KEY = 'deliveries.rejected.v1';
export const RECENT_DELIVERIES_KEY = 'deliveries.recent.v1';
/**
 * How many saved deliveries this phone remembers, and for how long. Review item 5 (owner 2026-11-09):
 * managers see today's drop-offs saved on their phone (they can't read the delivery history), so a whole
 * plant day must still be here at night; the screen keeps only today's.
 */
export const RECENT_MAX = 20;
export const RECENT_MAX_AGE_MS = 36 * 60 * 60 * 1000;

const LEGACY_FIELDS = ['staffId', 'pin', 'sessionId', 'pinStoredAt'] as const;

function isLine(v: unknown): v is DeliveryLine {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  return typeof o.washGroupId === 'string' && typeof o.bins === 'number';
}

function toPending(v: unknown): PendingDelivery | null {
  if (typeof v !== 'object' || v === null) return null;
  const o = v as Record<string, unknown>;
  if (
    typeof o.clientId !== 'string' ||
    typeof o.plantId !== 'string' ||
    typeof o.customerId !== 'string' ||
    !Array.isArray(o.lines) ||
    o.lines.length === 0 ||
    !o.lines.every(isLine) ||
    !(o.note === null || typeof o.note === 'string') ||
    typeof o.enteredAt !== 'string' ||
    typeof o.createdAt !== 'string'
  ) {
    return null;
  }
  return {
    clientId: o.clientId,
    plantId: o.plantId,
    customerId: o.customerId,
    lines: o.lines.map((l: DeliveryLine) => ({ washGroupId: l.washGroupId, bins: l.bins })),
    note: o.note,
    enteredAt: o.enteredAt,
    createdAt: o.createdAt,
    lastError: typeof o.lastError === 'string' ? o.lastError : null,
  };
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

function isRecent(v: unknown): v is RecentDelivery {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  return (
    typeof o.deliveryId === 'string' &&
    typeof o.clientId === 'string' &&
    typeof o.plantId === 'string' &&
    typeof o.customerId === 'string' &&
    Array.isArray(o.lines) &&
    o.lines.every(isLine) &&
    Array.isArray(o.queueItemIds) &&
    o.queueItemIds.every((x) => typeof x === 'string') &&
    typeof o.savedAt === 'string' &&
    (o.voidedAt === undefined || typeof o.voidedAt === 'string')
  );
}

function readRaw(store: KeyValueStore, key: string): unknown[] {
  try {
    const raw = store.getItem(key);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
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
  return readRaw(store, DELIVERY_OUTBOX_KEY)
    .map(toPending)
    .filter((d): d is PendingDelivery => d !== null);
}

export function readRejectedDeliveries(store: KeyValueStore): RejectedDelivery[] {
  return readRaw(store, REJECTED_DELIVERIES_KEY).filter(isRejected);
}

/** Saved deliveries of this phone, newest first, younger than RECENT_MAX_AGE_MS. */
export function readRecentDeliveries(
  store: KeyValueStore,
  nowMs: number = Date.now(),
): RecentDelivery[] {
  return readRaw(store, RECENT_DELIVERIES_KEY)
    .filter(isRecent)
    .filter((r) => {
      const t = Date.parse(r.savedAt);
      return !Number.isNaN(t) && nowMs - t <= RECENT_MAX_AGE_MS;
    })
    .sort((a, b) => b.savedAt.localeCompare(a.savedAt));
}

/** Remembers a saved delivery (at most RECENT_MAX, newest kept; same delivery id replaced). */
export function rememberRecentDelivery(
  store: KeyValueStore,
  r: RecentDelivery,
  nowMs: number = Date.now(),
): void {
  const rest = readRecentDeliveries(store, nowMs).filter((x) => x.deliveryId !== r.deliveryId);
  write(store, RECENT_DELIVERIES_KEY, [r, ...rest].slice(0, RECENT_MAX));
}

/** Marks a remembered delivery as cancelled from this phone. */
export function markRecentVoided(
  store: KeyValueStore,
  deliveryId: string,
  voidedAt: string,
  nowMs: number = Date.now(),
): void {
  write(
    store,
    RECENT_DELIVERIES_KEY,
    readRecentDeliveries(store, nowMs).map((r) =>
      r.deliveryId === deliveryId ? { ...r, voidedAt } : r,
    ),
  );
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
  return write(store, DELIVERY_OUTBOX_KEY, [...rest, d]);
}

function replace(store: KeyValueStore, clientId: string, d: PendingDelivery | null): void {
  const list = readPendingDeliveries(store);
  write(
    store,
    DELIVERY_OUTBOX_KEY,
    d
      ? list.map((x) => (x.clientId === clientId ? d : x))
      : list.filter((x) => x.clientId !== clientId),
  );
}

export interface DeliverySweep {
  tooOld: number;
  /** Deliveries from the entry-PIN era rewritten without their PIN. */
  legacyWiped: number;
}

/**
 * Housekeeping that never sends (before every flush and at app start): a delivery entered more than
 * 6 h ago can no longer be saved → refused list (OUT_OF_RANGE_TIMESTAMP); a delivery stored by an
 * older version is rewritten without its staff id / PIN / session.
 */
export function sweepDeliveries(store: KeyValueStore, nowMs: number = Date.now()): DeliverySweep {
  const age = (iso: string | undefined) => {
    const t = iso ? Date.parse(iso) : NaN;
    return Number.isNaN(t) ? Infinity : nowMs - t;
  };
  const legacyWiped = readRaw(store, DELIVERY_OUTBOX_KEY).filter(
    (v) => typeof v === 'object' && v !== null && LEGACY_FIELDS.some((k) => k in v),
  ).length;
  const kept: PendingDelivery[] = [];
  const old: RejectedDelivery[] = [];
  for (const d of readPendingDeliveries(store)) {
    if (age(d.enteredAt) > ENTRY_MAX_AGE_MS) old.push(toRejected(d, 'OUT_OF_RANGE_TIMESTAMP'));
    else kept.push(d);
  }
  addRejected(store, old);
  if (old.length > 0 || legacyWiped > 0) write(store, DELIVERY_OUTBOX_KEY, kept);
  return { tooOld: old.length, legacyWiped };
}

export type DeliveryRecordOutcome =
  | { kind: 'saved'; deliveryId: string | null; queueItemIds: string[] }
  | { kind: 'retry'; error: string }
  | { kind: 'rejected'; errorCode: string };

export interface DeliveryApi {
  record(d: PendingDelivery): Promise<DeliveryRecordOutcome>;
  /** Checked before every server call; false stops the flush (signed out / other account). */
  shouldContinue?(): Promise<boolean>;
}

export interface DeliveryFlushReport {
  saved: PendingDelivery[];
  rejected: RejectedDelivery[];
  remaining: PendingDelivery[];
}

/** The recent-list time of a saved delivery: its entry time if readable, else now. */
export function savedAtFor(enteredAt: string, nowMs: number): string {
  const t = Date.parse(enteredAt);
  return new Date(Number.isNaN(t) ? nowMs : t).toISOString();
}

/**
 * Sends every waiting delivery, oldest first. Storage is updated after every step, so nothing is lost
 * or sent twice (client_id makes a resend harmless anyway). A saved delivery with a delivery id goes
 * into the recent list.
 */
export async function flushDeliveries(
  store: KeyValueStore,
  api: DeliveryApi,
  nowMs: number = Date.now(),
): Promise<DeliveryFlushReport> {
  const report: DeliveryFlushReport = { saved: [], rejected: [], remaining: [] };
  const swept = sweepDeliveries(store, nowMs);
  if (swept.tooOld > 0) report.rejected.push(...readRejectedDeliveries(store).slice(-swept.tooOld));

  for (const d of readPendingDeliveries(store)) {
    if (api.shouldContinue && !(await api.shouldContinue())) break;
    const r = await api.record(d);
    if (r.kind === 'retry') {
      replace(store, d.clientId, { ...d, lastError: r.error });
      break; // offline: try everything later, in order
    }
    if (r.kind === 'saved') {
      report.saved.push(d);
      if (r.deliveryId) {
        rememberRecentDelivery(
          store,
          {
            deliveryId: r.deliveryId,
            clientId: d.clientId,
            plantId: d.plantId,
            customerId: d.customerId,
            lines: d.lines,
            queueItemIds: r.queueItemIds,
            // When it was entered, not when it finally sent: an offline 23:50 drop-off sent at
            // 00:10 stays under the day it was made ("today's drop-offs").
            savedAt: savedAtFor(d.enteredAt, nowMs),
          },
          nowMs,
        );
      }
    } else {
      const rej = toRejected(d, r.errorCode);
      addRejected(store, [rej]);
      report.rejected.push(rej);
    }
    replace(store, d.clientId, null);
  }
  report.remaining = readPendingDeliveries(store);
  return report;
}
