import { useTranslation } from 'react-i18next';
import { agoParts } from './ago';

const KEY = { min: 'dash.agoMin', hour: 'dash.agoHour', day: 'dash.agoDay' } as const;

/** (then, now) in epoch ms → "12 min ago", "2 h ago", "3 days ago" in the user's language. */
export function useAgo() {
  const { t } = useTranslation();
  return (thenMs: number, nowMs: number): string => {
    const p = agoParts(thenMs, nowMs);
    return t(KEY[p.unit], { count: p.count });
  };
}
