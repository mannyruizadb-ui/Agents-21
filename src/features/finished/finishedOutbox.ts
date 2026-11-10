// Outbox for finished-goods entries (owner 2026-11-10: the finishing tablet must never lose a line),
// the same pattern as the estimates and deliveries outboxes: an entry is written to device storage
// BEFORE the first attempt, with its client_id, and removed as soon as it is saved or refused. Saved
// entries are remembered for a while (server id), so Undo can void a line that already left, and so a
// line stays on screen until the server's own list shows it.
// Pure module: storage and the server calls are injected.

import type { KeyValueStore } from '../../lib/scopedStore';

export interface PendingFinished {
  clientId: string;
  areaId: string;
  itemTypeId: string;
  packs: number;
  loose: number;
  /** Pack items: the pack size the person saw (p_pack_size_used); null for unit items. */
  packSizeUsed: number | null;
  /** When it was entered (ISO), sent as p_occurred_at. */
  enteredAt: string;
  lastError: string | null;
}

export interface RejectedFinished {
  clientId: string;
  areaId: string;
  itemTypeId: string;
  packs: number;
  loose: number;
  packSizeUsed: number | null;
  enteredAt: string;
  errorCode: string;
}

/** A line saved from this device: its server id and what was sent. */
export interface SavedFinished {
  clientId: string;
  id: string;
  areaId: string;
  itemTypeId: string;
  packs: number;
  loose: number;
  /** pieces as the server computed it (or the preview when the server sent none). */
  pieces: number;
  occurredAt: string;
  savedAt: string;
  /** Set once voided from this device (Undo or a tap on the line). */
  voidedAt?: string;
}

export const FINISHED_OUTBOX_KEY = 'finished.outbox.v1';
export const REJECTED_FINISHED_KEY = 'finished.rejected.v1';
export const SAVED_FINISHED_KEY = 'finished.saved.v1';

/**
 * record_finished_goods accepts p_occurred_at up to 30 days back (a manager's line must also land in the
 * current or next shift, which the server checks). Past the window an entry can never be saved: it
 * moves to the refused list as OUT_OF_RANGE_TIMESTAMP instead of waiting forever.
 */
export const FINISHED_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000 - 10 * 60_000;
/** How many saved lines this device remembers, and for how long (a long shift and then some). */
export const SAVED_MAX = 200;
export const SAVED_MAX_AGE_MS = 24 * 60 * 60 * 1000;

const isNum = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);

function base(o: Record<string, unknown>): boolean {
  return (
    typeof o.clientId === 'string' &&
    typeof o.areaId === 'string' &&
    typeof o.itemTypeId === 'string' &&
    isNum(o.packs) &&
    isNum(o.loose) &&
    (o.packSizeUsed === null || isNum(o.packSizeUsed)) &&
    typeof o.enteredAt === 'string'
  );
}

function toPending(v: unknown): PendingFinished | null {
  if (typeof v !== 'object' || v === null) return null;
  const o = v as Record<string, unknown>;
  if (!base(o)) return null;
  const p = o as unknown as PendingFinished;
  return {
    clientId: p.clientId,
    areaId: p.areaId,
    itemTypeId: p.itemTypeId,
    packs: p.packs,
    loose: p.loose,
    packSizeUsed: p.packSizeUsed,
    enteredAt: p.enteredAt,
    lastError: typeof o.lastError === 'string' ? o.lastError : null,
  };
}

function isRejected(v: unknown): v is RejectedFinished {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  return base(o) && typeof o.errorCode === 'string';
}

function isSaved(v: unknown): v is SavedFinished {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  return (
    typeof o.clientId === 'string' &&
    typeof o.id === 'string' &&
    typeof o.areaId === 'string' &&
    typeof o.itemTypeId === 'string' &&
    isNum(o.packs) &&
    isNum(o.loose) &&
    isNum(o.pieces) &&
    typeof o.occurredAt === 'string' &&
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

export function readPendingFinished(store: KeyValueStore): PendingFinished[] {
  return readRaw(store, FINISHED_OUTBOX_KEY)
    .map(toPending)
    .filter((d): d is PendingFinished => d !== null);
}

export function readRejectedFinished(store: KeyValueStore): RejectedFinished[] {
  return readRaw(store, REJECTED_FINISHED_KEY).filter(isRejected);
}

/** Saved lines of this device, newest first, younger than SAVED_MAX_AGE_MS. */
export function readSavedFinished(
  store: KeyValueStore,
  nowMs: number = Date.now(),
): SavedFinished[] {
  return readRaw(store, SAVED_FINISHED_KEY)
    .filter(isSaved)
    .filter((r) => {
      const t = Date.parse(r.savedAt);
      return !Number.isNaN(t) && nowMs - t <= SAVED_MAX_AGE_MS;
    })
    .sort((a, b) => b.savedAt.localeCompare(a.savedAt));
}

export function rememberSaved(
  store: KeyValueStore,
  s: SavedFinished,
  nowMs: number = Date.now(),
): void {
  const rest = readSavedFinished(store, nowMs).filter((x) => x.clientId !== s.clientId);
  write(store, SAVED_FINISHED_KEY, [s, ...rest].slice(0, SAVED_MAX));
}

export function markSavedVoided(
  store: KeyValueStore,
  id: string,
  voidedAt: string,
  nowMs: number = Date.now(),
): void {
  write(
    store,
    SAVED_FINISHED_KEY,
    readSavedFinished(store, nowMs).map((r) => (r.id === id ? { ...r, voidedAt } : r)),
  );
}

/** Saves an entry before any attempt. False = the device refused to store it. */
export function addPendingFinished(store: KeyValueStore, d: PendingFinished): boolean {
  const rest = readPendingFinished(store).filter((x) => x.clientId !== d.clientId);
  return write(store, FINISHED_OUTBOX_KEY, [...rest, d]);
}

/** Takes a not-yet-sent entry off the device (Undo before it left). True = it was there. */
export function removePendingFinished(store: KeyValueStore, clientId: string): boolean {
  const list = readPendingFinished(store);
  if (!list.some((x) => x.clientId === clientId)) return false;
  return write(
    store,
    FINISHED_OUTBOX_KEY,
    list.filter((x) => x.clientId !== clientId),
  );
}

export function dismissRejectedFinished(store: KeyValueStore, clientId: string): void {
  write(
    store,
    REJECTED_FINISHED_KEY,
    readRejectedFinished(store).filter((r) => r.clientId !== clientId),
  );
}

function toRejected(d: PendingFinished, errorCode: string): RejectedFinished {
  return {
    clientId: d.clientId,
    areaId: d.areaId,
    itemTypeId: d.itemTypeId,
    packs: d.packs,
    loose: d.loose,
    packSizeUsed: d.packSizeUsed,
    enteredAt: d.enteredAt,
    errorCode,
  };
}

function addRejected(store: KeyValueStore, list: RejectedFinished[]): void {
  if (list.length > 0)
    write(store, REJECTED_FINISHED_KEY, [...readRejectedFinished(store), ...list]);
}

function replace(store: KeyValueStore, clientId: string, d: PendingFinished | null): void {
  const list = readPendingFinished(store);
  write(
    store,
    FINISHED_OUTBOX_KEY,
    d
      ? list.map((x) => (x.clientId === clientId ? d : x))
      : list.filter((x) => x.clientId !== clientId),
  );
}

/** Housekeeping that never sends: entries past the server's window → refused list. */
export function sweepFinished(store: KeyValueStore, nowMs: number = Date.now()): number {
  const kept: PendingFinished[] = [];
  const old: RejectedFinished[] = [];
  for (const d of readPendingFinished(store)) {
    const t = Date.parse(d.enteredAt);
    if (Number.isNaN(t) || nowMs - t > FINISHED_MAX_AGE_MS)
      old.push(toRejected(d, 'OUT_OF_RANGE_TIMESTAMP'));
    else kept.push(d);
  }
  if (old.length > 0) {
    addRejected(store, old);
    write(store, FINISHED_OUTBOX_KEY, kept);
  }
  return old.length;
}

export type FinishedRecordOutcome =
  | { kind: 'saved'; id: string | null; pieces: number | null; occurredAt: string | null }
  | { kind: 'retry'; error: string }
  | { kind: 'rejected'; errorCode: string };

export interface FinishedApi {
  record(d: PendingFinished): Promise<FinishedRecordOutcome>;
  /** Checked before every server call; false stops the flush (signed out / other account). */
  shouldContinue?(): Promise<boolean>;
}

export interface FinishedFlushReport {
  saved: PendingFinished[];
  rejected: RejectedFinished[];
  remaining: PendingFinished[];
}

/**
 * Sends every waiting entry, oldest first. Storage is updated after every step, so nothing is lost or
 * sent twice (client_id makes a resend harmless anyway). A saved entry with an id goes into the saved
 * list (for Undo and to keep it on screen until the server's list shows it).
 */
export async function flushFinished(
  store: KeyValueStore,
  api: FinishedApi,
  nowMs: number = Date.now(),
): Promise<FinishedFlushReport> {
  const report: FinishedFlushReport = { saved: [], rejected: [], remaining: [] };
  const tooOld = sweepFinished(store, nowMs);
  if (tooOld > 0) report.rejected.push(...readRejectedFinished(store).slice(-tooOld));

  for (const d of readPendingFinished(store)) {
    if (api.shouldContinue && !(await api.shouldContinue())) break;
    // Undo may have taken it off the device while an earlier entry was on the wire.
    if (!readPendingFinished(store).some((x) => x.clientId === d.clientId)) continue;
    const r = await api.record(d);
    if (r.kind === 'retry') {
      replace(store, d.clientId, { ...d, lastError: r.error });
      break; // offline: try everything later, in order
    }
    if (r.kind === 'saved') {
      report.saved.push(d);
      if (r.id) {
        rememberSaved(
          store,
          {
            clientId: d.clientId,
            id: r.id,
            areaId: d.areaId,
            itemTypeId: d.itemTypeId,
            packs: d.packs,
            loose: d.loose,
            pieces: r.pieces ?? d.packs * (d.packSizeUsed ?? 0) + d.loose,
            occurredAt: r.occurredAt ?? d.enteredAt,
            savedAt: new Date(nowMs).toISOString(),
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
  report.remaining = readPendingFinished(store);
  return report;
}
