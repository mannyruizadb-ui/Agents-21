// Outbox for soil estimates (owner 2026-11-04: offline entries send later). A batch is written to
// device storage BEFORE the first attempt with what is needed to send it: the entries, each with its
// client_id. 2026-11-07 (one sign-in method): entries no longer need an entry PIN; the signed-in
// account is the attribution, so nothing but the entries is stored. Batches saved by an older app
// version may still carry a staff id, PIN and session: they are read without them and rewritten at
// the next sweep, so the stored PIN is wiped.
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
  entries: OutboxEntry[];
  createdAt: string;
  /** Why it is stuck: 'network'… null = not tried / fine. */
  lastError: string | null;
}

export interface RejectedEstimate extends OutboxEntry {
  errorCode: string;
}

// Key names inside the signed-in user's scoped store (plantboard.<userId>.<name>, security H1).
export const OUTBOX_KEY = 'estimates.outbox.v1';
export const REJECTED_ESTIMATES_KEY = 'estimates.rejected.v1';

/**
 * The server accepts an estimate up to this long after it was made (p_entered_at window). Older
 * entries can never be saved: they move to the refused list as OUT_OF_RANGE_TIMESTAMP ("enter it
 * again") instead of waiting forever.
 */
export const ENTRY_MAX_AGE_MS = 6 * 60 * 60 * 1000;

/** Fields only batches from before 2026-11-07 carry (entry PIN era). */
const LEGACY_FIELDS = ['staffId', 'pin', 'sessionId', 'pinStoredAt'] as const;

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

function hasLegacy(v: unknown): boolean {
  return typeof v === 'object' && v !== null && LEGACY_FIELDS.some((k) => k in v);
}

/** A stored batch, without any legacy PIN fields; null when unreadable. */
function toBatch(v: unknown): OutboxBatch | null {
  if (typeof v !== 'object' || v === null) return null;
  const o = v as Record<string, unknown>;
  if (
    typeof o.batchId !== 'string' ||
    !Array.isArray(o.entries) ||
    !o.entries.every(isEntry) ||
    typeof o.createdAt !== 'string'
  ) {
    return null;
  }
  return {
    batchId: o.batchId,
    entries: o.entries.map((e: OutboxEntry) => ({ ...e })),
    createdAt: o.createdAt,
    lastError: typeof o.lastError === 'string' ? o.lastError : null,
  };
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

export function readOutbox(store: KeyValueStore): OutboxBatch[] {
  return readRaw(store, OUTBOX_KEY)
    .map(toBatch)
    .filter((b): b is OutboxBatch => b !== null);
}

export function readRejectedEstimates(store: KeyValueStore): RejectedEstimate[] {
  return readRaw(store, REJECTED_ESTIMATES_KEY).filter(
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
  return write(store, OUTBOX_KEY, [...list, batch]);
}

export interface SweepReport {
  /** Entries too old for the server, moved to the refused list. */
  tooOld: number;
  /** Batches from the entry-PIN era rewritten without their PIN. */
  legacyWiped: number;
}

/**
 * Housekeeping that never sends anything (run before every flush and at app start for every account
 * on the device):
 *  - entries made more than 6 h ago → refused list as OUT_OF_RANGE_TIMESTAMP (a batch left empty is
 *    dropped);
 *  - a batch saved by an older version with a staff id / PIN / session is rewritten without them.
 */
export function sweepOutbox(store: KeyValueStore, nowMs: number = Date.now()): SweepReport {
  const raw = readRaw(store, OUTBOX_KEY);
  const report: SweepReport = { tooOld: 0, legacyWiped: raw.filter(hasLegacy).length };
  const tooOld: RejectedEstimate[] = [];
  const kept: OutboxBatch[] = [];
  const age = (iso: string | undefined) => {
    const t = iso ? Date.parse(iso) : NaN;
    return Number.isNaN(t) ? Infinity : nowMs - t;
  };
  for (const b of readOutbox(store)) {
    const fresh = b.entries.filter((e) => age(e.enteredAt ?? b.createdAt) <= ENTRY_MAX_AGE_MS);
    for (const e of b.entries) {
      if (!fresh.includes(e)) tooOld.push({ ...e, errorCode: 'OUT_OF_RANGE_TIMESTAMP' });
    }
    if (fresh.length > 0) kept.push({ ...b, entries: fresh });
  }
  report.tooOld = tooOld.length;
  if (tooOld.length > 0) {
    write(store, REJECTED_ESTIMATES_KEY, [...readRejectedEstimates(store), ...tooOld]);
  }
  if (tooOld.length > 0 || report.legacyWiped > 0) write(store, OUTBOX_KEY, kept);
  return report;
}

function replaceBatch(store: KeyValueStore, batch: OutboxBatch | null, batchId: string): void {
  const rest = readOutbox(store).filter((b) => b.batchId !== batchId);
  write(store, OUTBOX_KEY, batch && batch.entries.length > 0 ? [...rest, batch] : rest);
}

export type RecordOutcome =
  | { kind: 'saved' }
  | { kind: 'retry'; error: string } // network / temporary
  | { kind: 'rejected'; errorCode: string };

export interface OutboxApi {
  record(entry: OutboxEntry): Promise<RecordOutcome>;
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
}

/**
 * Sends every batch, oldest first, each entry in order. Storage is updated after every entry, so a
 * crash mid-batch never sends an entry twice (client_id makes it harmless anyway) and never loses one.
 */
export async function flushOutbox(
  store: KeyValueStore,
  api: OutboxApi,
  nowMs: number = Date.now(),
): Promise<FlushReport> {
  const report: FlushReport = { saved: [], rejected: [], remaining: [] };

  // Drop entries the server can no longer accept; wipe legacy PINs.
  const swept = sweepOutbox(store, nowMs);
  if (swept.tooOld > 0) {
    report.rejected.push(...readRejectedEstimates(store).slice(-swept.tooOld));
  }

  batches: for (const initial of readOutbox(store)) {
    let batch: OutboxBatch = { ...initial };
    while (batch.entries.length > 0) {
      const entry = batch.entries[0] as OutboxEntry;
      if (api.shouldContinue && !(await api.shouldContinue())) break batches;
      const r = await api.record(entry);
      if (r.kind === 'retry') {
        replaceBatch(store, { ...batch, lastError: r.error }, batch.batchId);
        break batches; // offline: try everything later, in order
      }
      if (r.kind === 'saved') report.saved.push(entry);
      else {
        const rej = { ...entry, errorCode: r.errorCode };
        write(store, REJECTED_ESTIMATES_KEY, [...readRejectedEstimates(store), rej]);
        report.rejected.push(rej);
      }
      batch = { ...batch, entries: batch.entries.slice(1), lastError: null };
      replaceBatch(store, batch, batch.batchId);
    }
  }
  report.remaining = readOutbox(store);
  return report;
}
