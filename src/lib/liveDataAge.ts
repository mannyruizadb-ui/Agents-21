import { freshness } from '../features/washroom/washerTime';

// One freshness line per page (declutter 2026-11-09): of the live reads on screen, the one that is
// most overdue for its own refresh period decides "Updated X ago". Pure, for tests.

export interface LiveRead {
  /** When the data last arrived (ms); 0 = not loaded yet (ignored). */
  updatedAt: number;
  /** The read's refetch period (ms). */
  intervalMs: number;
  isError: boolean;
  isFetching: boolean;
}

export interface PageAge {
  updatedAt: number;
  refreshSeconds: number;
  isError: boolean;
  isFetching: boolean;
}

export function pageAge(reads: readonly LiveRead[], now: number): PageAge | null {
  const loaded = reads.filter((r) => r.updatedAt > 0 && r.intervalMs > 0);
  if (loaded.length === 0) return null;
  let worst = loaded[0] as LiveRead;
  let worstRatio = -1;
  for (const r of loaded) {
    const ratio = Math.max(0, now - r.updatedAt) / r.intervalMs;
    if (ratio > worstRatio) {
      worst = r;
      worstRatio = ratio;
    }
  }
  return {
    updatedAt: worst.updatedAt,
    refreshSeconds: Math.round(worst.intervalMs / 1000),
    isError: loaded.some((r) => r.isError),
    isFetching: loaded.some((r) => r.isFetching),
  };
}

/** True when the page line would warn (used by tests and callers that want only the band). */
export function pageAgeWarns(age: PageAge | null, now: number): boolean {
  if (!age) return false;
  const s = Math.max(0, Math.floor((now - age.updatedAt) / 1000));
  return age.isError || freshness(s, age.refreshSeconds) !== 'fresh';
}
