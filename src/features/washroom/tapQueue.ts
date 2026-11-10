import type { KeyValueStore } from '../../lib/scopedStore';
import { isOffQueueReason, type OffQueueReason } from './offQueue';

export type { KeyValueStore };

// Offline-safe washer start-taps. A tap is written to device storage BEFORE the first send attempt
// and removed only when the server has recorded it (or rejected it for good, in which case it moves to
// a "rejected" list the screen keeps showing until someone dismisses it). The client_id is generated
// once, at tap time, so every retry is the same tap to the server (start_washer_load is idempotent on
// p_client_id). Pure module: storage is injected so it is unit-testable without a browser.

export interface PendingTap {
  clientId: string;
  machineId: string;
  /** Set when the washman picked "other wash group"; null = what the queue says is next. */
  washGroupId: string | null;
  /** Device time of the tap (ISO). Shown only; the server records the time it receives the tap. */
  tappedAt: string;
  attempts: number;
  /** Last error code or message from a failed attempt, for the screen. */
  lastError: string | null;
  /** Owner 2026-11-06: the person confirmed starting another load on a washer that was still running. */
  confirmRunning?: boolean;
  /** Owner 2026-11-09: why a start differs from the queue's next for this washer. */
  offQueueReason?: OffQueueReason;
}

export interface RejectedTap extends PendingTap {
  rejectedAt: string;
  /** PRD §5.1 code (VALIDATION_FAILED, NOT_AUTHORIZED, …). */
  errorCode: string;
}

// Key names inside the signed-in user's scoped store (plantboard.<userId>.<name>).
export const PENDING_KEY = 'washerTaps.pending.v1';
export const REJECTED_KEY = 'washerTaps.rejected.v1';

function isString(v: unknown): v is string {
  return typeof v === 'string';
}

function isPendingTap(v: unknown): v is PendingTap {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  return (
    isString(o.clientId) &&
    isString(o.machineId) &&
    (o.washGroupId === null || isString(o.washGroupId)) &&
    isString(o.tappedAt) &&
    typeof o.attempts === 'number' &&
    (o.lastError === null || isString(o.lastError))
  );
}

function isRejectedTap(v: unknown): v is RejectedTap {
  if (!isPendingTap(v)) return false;
  const o = v as unknown as Record<string, unknown>;
  return isString(o.rejectedAt) && isString(o.errorCode);
}

function readList<T>(store: KeyValueStore, key: string, guard: (v: unknown) => v is T): T[] {
  let raw: string | null;
  try {
    raw = store.getItem(key);
  } catch {
    return [];
  }
  if (!raw) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter(guard) : [];
  } catch {
    return [];
  }
}

/** Returns false when the device refused to store (private mode, quota): the caller must say so. */
function writeList(store: KeyValueStore, key: string, list: readonly unknown[]): boolean {
  try {
    store.setItem(key, JSON.stringify(list));
    return true;
  } catch {
    return false;
  }
}

/** A stored reason that is not one of the four codes is dropped (the tap itself is kept). */
function cleanReason<T extends PendingTap>(tap: T): T {
  if (tap.offQueueReason === undefined || isOffQueueReason(tap.offQueueReason)) return tap;
  const copy = { ...tap };
  delete copy.offQueueReason;
  return copy;
}

export function readPending(store: KeyValueStore): PendingTap[] {
  return readList(store, PENDING_KEY, isPendingTap).map(cleanReason);
}

export function readRejected(store: KeyValueStore): RejectedTap[] {
  return readList(store, REJECTED_KEY, isRejectedTap).map(cleanReason);
}

export function newTap(
  machineId: string,
  washGroupId: string | null,
  clientId: string,
  now: Date,
  confirmRunning = false,
  offQueueReason: OffQueueReason | null = null,
): PendingTap {
  return {
    clientId,
    machineId,
    washGroupId,
    tappedAt: now.toISOString(),
    attempts: 0,
    lastError: null,
    ...(confirmRunning ? { confirmRunning: true } : {}),
    ...(offQueueReason ? { offQueueReason } : {}),
  };
}

/**
 * A re-sent tap keeps the refused tap's own time (when the washer was really loaded) while the server
 * still accepts it: start_washer_load refuses a p_tapped_at older than 30 min, so past 29 min (or an
 * unreadable / future time) it falls back to `now` (server-clock corrected by the caller).
 */
export const RESEND_MAX_AGE_MS = 29 * 60_000;

/** The time a re-sent tap carries: the original tap time if still inside the window, else now. */
export function resendTime(originalIso: string, now: Date): Date {
  const original = Date.parse(originalIso);
  const age = now.getTime() - original;
  return Number.isFinite(original) && age >= 0 && age <= RESEND_MAX_AGE_MS
    ? new Date(original)
    : now;
}

/**
 * A NEW tap that re-sends a refused one with the missing answer added (WASHER_RUNNING → "Start
 * anyway"; OFF_QUEUE_REASON_REQUIRED → a reason). Keeps the machine, the chosen group, the tap time
 * (see resendTime) and every answer already given, so the retry cannot fail on the other question
 * again. New client_id: the refused one was never recorded. `now` = server-corrected current time.
 */
export function resendTap(
  refused: PendingTap,
  clientId: string,
  now: Date,
  add: { confirmRunning?: boolean; offQueueReason?: OffQueueReason },
): PendingTap {
  return newTap(
    refused.machineId,
    refused.washGroupId,
    clientId,
    resendTime(refused.tappedAt, now),
    add.confirmRunning ?? refused.confirmRunning ?? false,
    add.offQueueReason ?? refused.offQueueReason ?? null,
  );
}

/** Saves a tap (no-op if its clientId is already saved). Returns false if storage failed. */
export function addPending(store: KeyValueStore, tap: PendingTap): boolean {
  const list = readPending(store);
  if (list.some((t) => t.clientId === tap.clientId)) return true;
  return writeList(store, PENDING_KEY, [...list, tap]);
}

/** Removes a not-yet-sent tap (Undo before it reached the server). True if it was there. */
export function removePending(store: KeyValueStore, clientId: string): boolean {
  const list = readPending(store);
  const next = list.filter((t) => t.clientId !== clientId);
  if (next.length === list.length) return false;
  writeList(store, PENDING_KEY, next);
  return true;
}

export function dismissRejected(store: KeyValueStore, clientId: string): void {
  writeList(
    store,
    REJECTED_KEY,
    readRejected(store).filter((t) => t.clientId !== clientId),
  );
}

export type SendOutcome<R> =
  | { kind: 'sent'; result: R }
  /** Temporary (network, rate limit): keep it, try again later. */
  | { kind: 'retry'; error: string }
  /** The server will never accept it (VALIDATION_FAILED, NOT_AUTHORIZED…). */
  | { kind: 'rejected'; errorCode: string };

export interface FlushResult<R> {
  sent: { tap: PendingTap; result: R }[];
  rejected: RejectedTap[];
  remaining: PendingTap[];
}

/**
 * Sends pending taps oldest first. Stops at the first temporary failure, so taps reach the server in
 * the order they were made (the queue item each one takes depends on the ones before it).
 * Storage is re-read before each step and written after each one, so a tap added or undone during
 * a flush is never lost or resurrected.
 */
export async function flushPending<R>(
  store: KeyValueStore,
  send: (tap: PendingTap) => Promise<SendOutcome<R>>,
  now: () => Date = () => new Date(),
  /** Checked before EVERY send (security re-review note 3): false stops the flush at once. */
  shouldContinue: () => Promise<boolean> = async () => true,
): Promise<FlushResult<R>> {
  const result: FlushResult<R> = { sent: [], rejected: [], remaining: [] };
  const seen = new Set<string>();
  for (;;) {
    const tap = readPending(store).find((t) => !seen.has(t.clientId));
    if (!tap) break;
    seen.add(tap.clientId);
    if (!(await shouldContinue())) break;
    const outcome = await send(tap);
    if (outcome.kind === 'sent') {
      removePending(store, tap.clientId);
      result.sent.push({ tap, result: outcome.result });
      continue;
    }
    if (outcome.kind === 'rejected') {
      const rejected: RejectedTap = {
        ...tap,
        attempts: tap.attempts + 1,
        lastError: outcome.errorCode,
        errorCode: outcome.errorCode,
        rejectedAt: now().toISOString(),
      };
      // Keep it visible before dropping it from the pending list: never lose a tap silently.
      writeList(store, REJECTED_KEY, [...readRejected(store), rejected]);
      removePending(store, tap.clientId);
      result.rejected.push(rejected);
      continue;
    }
    // Temporary failure: record the attempt (if the tap was not undone meanwhile) and stop.
    const list = readPending(store);
    writeList(
      store,
      PENDING_KEY,
      list.map((t) =>
        t.clientId === tap.clientId
          ? { ...t, attempts: t.attempts + 1, lastError: outcome.error }
          : t,
      ),
    );
    break;
  }
  result.remaining = readPending(store);
  return result;
}

export { memoryStore } from '../../lib/scopedStore';
