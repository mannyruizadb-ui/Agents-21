import { useSyncExternalStore } from 'react';

/** Live `matchMedia(query).matches` (false where matchMedia is missing, e.g. in tests). */
export function useMediaQuery(query: string): boolean {
  return useSyncExternalStore(
    (onChange) => {
      if (typeof window === 'undefined' || !window.matchMedia) return () => undefined;
      const m = window.matchMedia(query);
      m.addEventListener('change', onChange);
      return () => m.removeEventListener('change', onChange);
    },
    () =>
      typeof window !== 'undefined' && window.matchMedia ? window.matchMedia(query).matches : false,
    () => false,
  );
}

/** The owner dashboard fits the screen (no page scroll) on a desktop at least this big. */
export const DESKTOP_FIT_QUERY = '(min-width: 1280px) and (min-height: 640px)';
