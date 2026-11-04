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
}

export interface RejectedTap extends PendingTap {
  rejectedAt: string;
  /** PRD §5.1 code (VALIDATION_FAILED, NOT_AUTHORIZED, …). */
  errorCode: string;
}

/** The subset of the Web Storage API we use; localStorage in the app, a Map in tests. */
export interface KeyValueStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export const PENDING_KEY = 'plantboard.washerTaps.pending.v1';
export const REJECTED_KEY = 'plantboard.washerTaps.rejected.v1';

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

export function readPending(store: KeyValueStore): PendingTap[] {
  return readList(store, PENDING_KEY, isPendingTap);
}

export function readRejected(store: KeyValueStore): RejectedTap[] {
  return readList(store, REJECTED_KEY, isRejectedTap);
}

export function newTap(
  machineId: string,
  washGroupId: string | null,
  clientId: string,
  now: Date,
): PendingTap {
  return {
    clientId,
    machineId,
    washGroupId,
    tappedAt: now.toISOString(),
    attempts: 0,
    lastError: null,
  };
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
): Promise<FlushResult<R>> {
  const result: FlushResult<R> = { sent: [], rejected: [], remaining: [] };
  const seen = new Set<string>();
  for (;;) {
    const tap = readPending(store).find((t) => !seen.has(t.clientId));
    if (!tap) break;
    seen.add(tap.clientId);
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

/** A Map-backed store for tests and as a fallback when localStorage is unavailable. */
export function memoryStore(): KeyValueStore {
  const map = new Map<string, string>();
  return {
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => {
      map.set(k, v);
    },
  };
}
