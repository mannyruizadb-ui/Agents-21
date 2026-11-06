// Outbox for soil estimates (owner 2026-11-04: one PIN for the batch; offline entries send later
// without asking for the PIN again). A batch is written to device storage BEFORE the first attempt
// with what is needed to send it: the entries (each with its client_id), the entry person's id and
// PIN, and the staff session if one is open. The whole record, PIN included, is wiped as soon as
// every entry is saved or refused. PINs are attribution only (A8), not security; storing the PIN
// until the batch sends is the owner-approved trade-off (CLAUDE.md, pending security sign-off).
// Pure module: storage and the server calls are injected.

import type { KeyValueStore } from '../washroom/tapQueue';
import type { EstimateUnit } from './estimateMath';

export interface OutboxEntry {
  clientId: string;
  washGroupId: string;
  qty: number;
  unit: EstimateUnit;
  /** When the estimate was made (server-clock corrected), sent as p_entered_at. */
  enteredAt?: string;
}

export interface OutboxBatch {
  batchId: string;
  staffId: string;
  pin: string;
  /** Last staff session that worked (reused while the server's reuse window lasts). */
  sessionId: string | null;
  entries: OutboxEntry[];
  createdAt: string;
  /** When the PIN was stored (at save, or when it was entered again); its 6-hour clock. */
  pinStoredAt?: string;
  /** Why it is stuck: 'network', 'PIN_INVALID', 'STAFF_LOCKED'… null = not tried / fine. */
  lastError: string | null;
}

export interface RejectedEstimate extends OutboxEntry {
  errorCode: string;
}

// Key names inside the signed-in user's scoped store (plantboard.<userId>.<name>, security H1).
export const OUTBOX_KEY = 'estimates.outbox.v1';
export const REJECTED_ESTIMATES_KEY = 'estimates.rejected.v1';

/**
 * A stored PIN is wiped this long after it was stored (security M2, re-review note 1). The entries
 * stay and wait for someone to enter the PIN again.
 */
export const PIN_MAX_AGE_MS = 6 * 60 * 60 * 1000;

/**
 * The server accepts an estimate up to this long after it was made (p_entered_at window). Older
 * entries can never be saved: they move to the refused list as OUT_OF_RANGE_TIMESTAMP ("enter it
 * again") instead of waiting forever.
 */
export const ENTRY_MAX_AGE_MS = 6 * 60 * 60 * 1000;

function isEntry(v: unknown): v is OutboxEntry {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  return (
    typeof o.clientId === 'string' &&
    typeof o.washGroupId === 'string' &&
    typeof o.qty === 'number' &&
    (o.unit === 'load' || o.unit === 'basket' || o.unit === 'bin') &&
    (o.enteredAt === undefined || typeof o.enteredAt === 'string')
  );
}

function isBatch(v: unknown): v is OutboxBatch {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  return (
    typeof o.batchId === 'string' &&
    typeof o.staffId === 'string' &&
    typeof o.pin === 'string' &&
    (o.sessionId === null || typeof o.sessionId === 'string') &&
    Array.isArray(o.entries) &&
    o.entries.every(isEntry) &&
    typeof o.createdAt === 'string' &&
    (o.pinStoredAt === undefined || typeof o.pinStoredAt === 'string')
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

export function readOutbox(store: KeyValueStore): OutboxBatch[] {
  return read(store, OUTBOX_KEY, isBatch);
}

export function readRejectedEstimates(store: KeyValueStore): RejectedEstimate[] {
  return read(
    store,
    REJECTED_ESTIMATES_KEY,
    (v): v is RejectedEstimate =>
      isEntry(v) && typeof (v as unknown as Record<string, unknown>).errorCode === 'string',
  );
}

export function dismissRejectedEstimate(store: KeyValueStore, clientId: string): void {
  write(
    store,
    REJECTED_ESTIMATES_KEY,
    readRejectedEstimates(store).filter((r) => r.clientId !== clientId),
  );
}

/** Saves a batch (before any attempt). False = the device refused to store it. */
export function addBatch(store: KeyValueStore, batch: OutboxBatch): boolean {
  const list = readOutbox(store).filter((b) => b.batchId !== batch.batchId);
  const stamped =
    batch.pin && !batch.pinStoredAt ? { ...batch, pinStoredAt: batch.createdAt } : batch;
  return write(store, OUTBOX_KEY, [...list, stamped]);
}

/**
 * Replaces the PIN of stuck batches for one person (after "enter the PIN again"). Restarts the PIN's
 * 6-hour clock, so an older batch can still be sent (re-review note 1).
 */
export function updatePin(
  store: KeyValueStore,
  staffId: string,
  pin: string,
  nowMs: number = Date.now(),
): void {
  const at = new Date(nowMs).toISOString();
  write(
    store,
    OUTBOX_KEY,
    readOutbox(store).map((b) =>
      b.staffId === staffId ? { ...b, pin, pinStoredAt: at, sessionId: null, lastError: null } : b,
    ),
  );
}

export interface SweepReport {
  /** Entries too old for the server, moved to the refused list. */
  tooOld: number;
  /** PINs wiped because they were stored more than 6 h ago. */
  pinsWiped: number;
}

/**
 * Housekeeping that never sends anything (run before every flush and at app start for every account
 * on the device, re-review note 2):
 *  - entries made more than 6 h ago → refused list as OUT_OF_RANGE_TIMESTAMP (a batch left empty is
 *    dropped, which also wipes its PIN);
 *  - a PIN stored more than 6 h ago → wiped; the batch waits for the PIN.
 */
export function sweepOutbox(store: KeyValueStore, nowMs: number = Date.now()): SweepReport {
  const report: SweepReport = { tooOld: 0, pinsWiped: 0 };
  const tooOld: RejectedEstimate[] = [];
  const kept: OutboxBatch[] = [];
  const age = (iso: string | undefined) => {
    const t = iso ? Date.parse(iso) : NaN;
    return Number.isNaN(t) ? Infinity : nowMs - t;
  };
  const before = readOutbox(store);
  for (const b of before) {
    const fresh = b.entries.filter((e) => age(e.enteredAt ?? b.createdAt) <= ENTRY_MAX_AGE_MS);
    for (const e of b.entries) {
      if (!fresh.includes(e)) tooOld.push({ ...e, errorCode: 'OUT_OF_RANGE_TIMESTAMP' });
    }
    if (fresh.length === 0) continue;
    let next: OutboxBatch = { ...b, entries: fresh };
    if (next.pin && age(next.pinStoredAt ?? next.createdAt) > PIN_MAX_AGE_MS) {
      next = { ...next, pin: '', sessionId: null, lastError: 'PIN_EXPIRED' };
      report.pinsWiped += 1;
    }
    kept.push(next);
  }
  report.tooOld = tooOld.length;
  if (tooOld.length > 0) {
    write(store, REJECTED_ESTIMATES_KEY, [...readRejectedEstimates(store), ...tooOld]);
  }
  if (tooOld.length > 0 || report.pinsWiped > 0) write(store, OUTBOX_KEY, kept);
  return report;
}

function replaceBatch(store: KeyValueStore, batch: OutboxBatch | null, batchId: string): void {
  const rest = readOutbox(store).filter((b) => b.batchId !== batchId);
  // An empty batch is dropped entirely: that wipes the PIN.
  write(store, OUTBOX_KEY, batch && batch.entries.length > 0 ? [...rest, batch] : rest);
}

export type RecordOutcome =
  | { kind: 'saved' }
  | { kind: 'session' } // STAFF_SESSION_REQUIRED: open a new session with the stored PIN
  | { kind: 'retry'; error: string } // network / temporary
  | { kind: 'rejected'; errorCode: string };

export type SessionOutcome =
  | { kind: 'ok'; sessionId: string }
  | { kind: 'pin'; error: string } // PIN_INVALID | STAFF_LOCKED | PIN_NEEDED: someone must enter the PIN again
  | { kind: 'retry'; error: string }
  | { kind: 'rejected'; errorCode: string }; // e.g. person deactivated

export interface OutboxApi {
  record(entry: OutboxEntry, sessionId: string): Promise<RecordOutcome>;
  startSession(staffId: string, pin: string): Promise<SessionOutcome>;
  /**
   * Checked before EVERY server call (re-review note 3): false stops the flush at once, e.g. when
   * the account signed out or changed mid-flush. Default: always continue.
   */
  shouldContinue?(): Promise<boolean>;
}

export interface FlushReport {
  saved: OutboxEntry[];
  rejected: RejectedEstimate[];
  /** Batches still waiting after this flush. */
  remaining: OutboxBatch[];
  /** Set when a batch needs the PIN again (wrong or changed PIN, locked person). */
  needsPin: { staffId: string; error: string } | null;
  /** The newest working session per person, for the reuse cache. */
  sessions: { staffId: string; sessionId: string }[];
}

/**
 * Sends every batch, oldest first, each entry in order. A missing or spent session is replaced by a
 * new one opened with the stored PIN (no second PIN entry for the person). Storage is updated after
 * every entry, so a crash mid-batch never sends an entry twice (client_id makes it harmless anyway)
 * and never loses one.
 */
export async function flushOutbox(
  store: KeyValueStore,
  api: OutboxApi,
  nowMs: number = Date.now(),
): Promise<FlushReport> {
  const report: FlushReport = {
    saved: [],
    rejected: [],
    remaining: [],
    needsPin: null,
    sessions: [],
  };
  const rejectAll = (b: OutboxBatch, code: string) => {
    const r = b.entries.map((e) => ({ ...e, errorCode: code }));
    write(store, REJECTED_ESTIMATES_KEY, [...readRejectedEstimates(store), ...r]);
    report.rejected.push(...r);
    replaceBatch(store, null, b.batchId);
  };

  // Security M2 / re-review note 1: drop entries the server can no longer accept; expire old PINs.
  const swept = sweepOutbox(store, nowMs);
  if (swept.tooOld > 0) {
    report.rejected.push(...readRejectedEstimates(store).slice(-swept.tooOld));
  }

  batches: for (const initial of readOutbox(store)) {
    let batch: OutboxBatch = { ...initial };
    let freshSession = false; // a session opened in this flush: don't open another on its refusal
    while (batch.entries.length > 0) {
      const entry = batch.entries[0] as OutboxEntry;
      if (!batch.sessionId) {
        // No PIN on the device (wiped after a wrong PIN or after 72 h): wait for someone to enter it.
        if (!batch.pin) {
          report.needsPin = { staffId: batch.staffId, error: batch.lastError ?? 'PIN_NEEDED' };
          continue batches;
        }
        if (api.shouldContinue && !(await api.shouldContinue())) break batches;
        const s = await api.startSession(batch.staffId, batch.pin);
        if (s.kind === 'pin') {
          // Security M1: drop the refused PIN so it is never retried (5 misses lock the person out).
          batch = { ...batch, pin: '', lastError: s.error };
          replaceBatch(store, batch, batch.batchId);
          report.needsPin = { staffId: batch.staffId, error: s.error };
          continue batches;
        }
        if (s.kind === 'retry') {
          replaceBatch(store, { ...batch, lastError: s.error }, batch.batchId);
          break batches; // offline: try everything later, in order
        }
        if (s.kind === 'rejected') {
          rejectAll(batch, s.errorCode);
          continue batches;
        }
        batch = { ...batch, sessionId: s.sessionId, lastError: null };
        freshSession = true;
        replaceBatch(store, batch, batch.batchId);
      }
      if (api.shouldContinue && !(await api.shouldContinue())) break batches;
      const r = await api.record(entry, batch.sessionId as string);
      if (r.kind === 'saved' || r.kind === 'rejected') {
        if (r.kind === 'saved') report.saved.push(entry);
        else {
          const rej = { ...entry, errorCode: r.errorCode };
          write(store, REJECTED_ESTIMATES_KEY, [...readRejectedEstimates(store), rej]);
          report.rejected.push(rej);
        }
        batch = { ...batch, entries: batch.entries.slice(1), lastError: null };
        freshSession = false; // the session was used: a later refusal just means it is spent
        replaceBatch(store, batch, batch.batchId);
        continue;
      }
      if (r.kind === 'session') {
        if (freshSession) {
          // A brand-new session was refused: give up on this entry rather than loop.
          const rej = { ...entry, errorCode: 'STAFF_SESSION_REQUIRED' };
          write(store, REJECTED_ESTIMATES_KEY, [...readRejectedEstimates(store), rej]);
          report.rejected.push(rej);
          batch = { ...batch, entries: batch.entries.slice(1) };
          freshSession = false;
        }
        batch = { ...batch, sessionId: null };
        replaceBatch(store, batch, batch.batchId);
        continue;
      }
      replaceBatch(store, { ...batch, lastError: r.error }, batch.batchId);
      break batches;
    }
    if (batch.sessionId)
      report.sessions.push({ staffId: batch.staffId, sessionId: batch.sessionId });
  }
  report.remaining = readOutbox(store);
  return report;
}
