// Late-tap alarm (owner 2026-11-05: a 30-minute-late tap must be "alarmed"). A washer start-tap is
// in alarm when:
//  - the server refused it as more than 30 minutes late (OUT_OF_RANGE_TIMESTAMP), or
//  - it has been waiting on this device, unsent, for more than 20 minutes (it will soon be too late).
// Dismissing an alarm only hides it: the tap itself is never dropped (a pending tap keeps retrying;
// a refused one stays in the refused list). Pure module; storage is injected.

import type { KeyValueStore } from '../../lib/scopedStore';
import type { PendingTap, RejectedTap } from './tapQueue';

export const STUCK_AFTER_MS = 20 * 60 * 1000;
export const ACK_KEY = 'washerTaps.alarmAck.v1';

export type TapAlarmKind = 'late' | 'stuck';

export interface TapAlarm {
  clientId: string;
  machineId: string;
  tappedAt: string;
  kind: TapAlarmKind;
  /** Whole minutes the tap has waited (stuck only). */
  waitingMinutes: number | null;
}

export function tapAlarms(
  pending: readonly PendingTap[],
  rejected: readonly RejectedTap[],
  acked: ReadonlySet<string>,
  nowMs: number,
): TapAlarm[] {
  const alarms: TapAlarm[] = [];
  for (const r of rejected) {
    if (r.errorCode === 'OUT_OF_RANGE_TIMESTAMP' && !acked.has(r.clientId)) {
      alarms.push({
        clientId: r.clientId,
        machineId: r.machineId,
        tappedAt: r.tappedAt,
        kind: 'late',
        waitingMinutes: null,
      });
    }
  }
  for (const p of pending) {
    const t = Date.parse(p.tappedAt);
    if (Number.isNaN(t) || acked.has(p.clientId)) continue;
    const waited = nowMs - t;
    if (waited > STUCK_AFTER_MS) {
      alarms.push({
        clientId: p.clientId,
        machineId: p.machineId,
        tappedAt: p.tappedAt,
        kind: 'stuck',
        waitingMinutes: Math.floor(waited / 60000),
      });
    }
  }
  return alarms.sort((a, b) => a.tappedAt.localeCompare(b.tappedAt));
}

export function readAcked(store: KeyValueStore): Set<string> {
  try {
    const parsed: unknown = JSON.parse(store.getItem(ACK_KEY) ?? '[]');
    return new Set(
      Array.isArray(parsed) ? parsed.filter((x): x is string => typeof x === 'string') : [],
    );
  } catch {
    return new Set();
  }
}

/**
 * Hides one alarm. Acknowledgements for taps that no longer exist are pruned, so the list never
 * grows without bound.
 */
export function ackAlarm(
  store: KeyValueStore,
  clientId: string,
  existingIds: readonly string[],
): void {
  const keep = new Set(existingIds);
  const next = [...readAcked(store)].filter((id) => keep.has(id));
  next.push(clientId);
  try {
    store.setItem(ACK_KEY, JSON.stringify([...new Set(next)]));
  } catch {
    // not remembered: the alarm shows again after a reload, which is the safe side
  }
}
