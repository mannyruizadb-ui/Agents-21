import { useQueryClient } from '@tanstack/react-query';
import { pageAge, type LiveRead, type PageAge } from './liveDataAge';

/**
 * The page's one freshness line, from the LIVE reads on screen: every active query with a numeric
 * refetchInterval (setup reads such as roles or areas have none and are left out). Re-evaluated on
 * each render; callers re-render on a clock (useNow).
 */
export function usePageAge(now: number): PageAge | null {
  const qc = useQueryClient();
  const reads: LiveRead[] = [];
  for (const q of qc.getQueryCache().findAll({ type: 'active' })) {
    let intervalMs = 0;
    for (const o of q.observers) {
      const iv = o.options.refetchInterval;
      if (typeof iv === 'number' && iv > 0) intervalMs = Math.max(intervalMs, iv);
    }
    if (!intervalMs) continue;
    reads.push({
      updatedAt: q.state.dataUpdatedAt,
      intervalMs,
      isError: q.state.status === 'error',
      isFetching: q.state.fetchStatus === 'fetching',
    });
  }
  return pageAge(reads, now);
}
