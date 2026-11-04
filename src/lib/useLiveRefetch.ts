import { useEffect, useRef } from 'react';

/**
 * Refetches live data on mount, when the window regains focus, when the device comes back online and
 * when the tab becomes visible (CLAUDE.md: never trust Realtime alone). The periodic refetch is the
 * query's own refetchInterval.
 */
export function useLiveRefetch(refetch: () => unknown, enabled = true): void {
  const ref = useRef(refetch);
  useEffect(() => {
    ref.current = refetch;
  }, [refetch]);

  useEffect(() => {
    if (!enabled) return;
    const run = () => void ref.current();
    const onVisible = () => {
      if (document.visibilityState === 'visible') run();
    };
    run();
    window.addEventListener('focus', run);
    window.addEventListener('online', run);
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      window.removeEventListener('focus', run);
      window.removeEventListener('online', run);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [enabled]);
}
