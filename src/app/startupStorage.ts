import { scopedStore, type KeyValueStore } from '../lib/scopedStore';
import { OUTBOX_KEY, sweepOutbox } from '../features/estimates/estimateOutbox';
import { DELIVERY_OUTBOX_KEY, sweepDeliveries } from '../features/deliveries/deliveryOutbox';

// Run once at app start, before anyone signs in (security re-review notes 2 and 5). Sends nothing.
//  - Deletes the keys from before per-account storage (they could hold another person's PIN).
//  - For EVERY account with an estimates outbox on this device: expires PINs older than 6 h and
//    moves entries the server can no longer accept to that account's refused list. Without this, a
//    PIN would stay on a shared phone until that same account signed in again.
//  - The same for every account's customer-deliveries outbox (2026-11-07).

export interface EnumerableStore extends KeyValueStore {
  keys(): string[];
  removeItem(key: string): void;
}

/** Keys written before storage was scoped per account (2026-11-04). */
export const LEGACY_KEYS = [
  'plantboard.estimates.outbox.v1',
  'plantboard.estimates.rejected.v1',
  'plantboard.estimates.lastStaff.v1',
  'plantboard.staffSession.v1',
  'plantboard.washerTaps.pending.v1',
  'plantboard.washerTaps.rejected.v1',
] as const;

const OUTBOX_PATTERN = new RegExp(
  `^plantboard\\.([0-9a-fA-F-]{36})\\.${OUTBOX_KEY.replace(/\./g, '\\.')}$`,
);

const DELIVERY_PATTERN = new RegExp(
  `^plantboard\\.([0-9a-fA-F-]{36})\\.${DELIVERY_OUTBOX_KEY.replace(/\./g, '\\.')}$`,
);

export interface StartupReport {
  legacyRemoved: number;
  accounts: number;
  pinsWiped: number;
  tooOld: number;
}

export function startupStorageSweep(
  base: EnumerableStore,
  nowMs: number = Date.now(),
): StartupReport {
  const report: StartupReport = { legacyRemoved: 0, accounts: 0, pinsWiped: 0, tooOld: 0 };
  for (const key of LEGACY_KEYS) {
    if (base.getItem(key) !== null) {
      base.removeItem(key);
      report.legacyRemoved += 1;
    }
  }
  for (const key of base.keys()) {
    const userId = OUTBOX_PATTERN.exec(key)?.[1];
    if (userId) {
      report.accounts += 1;
      const r = sweepOutbox(scopedStore(base, userId), nowMs);
      report.pinsWiped += r.pinsWiped;
      report.tooOld += r.tooOld;
      continue;
    }
    const deliveryUser = DELIVERY_PATTERN.exec(key)?.[1];
    if (!deliveryUser) continue;
    const r = sweepDeliveries(scopedStore(base, deliveryUser), nowMs);
    report.pinsWiped += r.pinsWiped;
    report.tooOld += r.tooOld;
  }
  return report;
}

/** window.localStorage as an EnumerableStore; null when the browser refuses access. */
export function localStorageEnumerable(): EnumerableStore | null {
  try {
    const ls = window.localStorage;
    return {
      keys: () =>
        Array.from({ length: ls.length }, (_, i) => ls.key(i)).filter((k): k is string => !!k),
      getItem: (k) => ls.getItem(k),
      setItem: (k, v) => ls.setItem(k, v),
      removeItem: (k) => ls.removeItem(k),
    };
  } catch {
    return null;
  }
}

/** Never blocks the app from starting. */
export function runStartupStorageSweep(): void {
  try {
    const ls = localStorageEnumerable();
    if (ls) startupStorageSweep(ls);
  } catch {
    // storage unavailable or corrupt: nothing to clean
  }
}
