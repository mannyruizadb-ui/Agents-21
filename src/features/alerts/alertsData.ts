import { useQuery } from '@tanstack/react-query';
import type { KeyValueStore } from '../../lib/scopedStore';
import { userStore } from '../../lib/scopedStore';
import { supabase } from '../../lib/supabase';
import { appErrorCode, toRpcError } from '../washroom/rpcError';
import { LIVE_REFETCH_MS } from '../washroom/washroomData';
import type { AlertRow } from './alertView';

// get_my_alerts / get_my_alert_count (owner or manager of the plant). Until the functions reach the
// cloud, a missing function (PostgREST PGRST202 / 404) or NOT_AUTHORIZED is "unavailable", not an
// error: the page shows a notice and the nav shows no badge.

export type AlertsResult = { available: true; rows: AlertRow[] } | { available: false };

interface PgErr {
  code?: unknown;
  message?: unknown;
}

export function isUnavailable(error: unknown): boolean {
  if (appErrorCode(error) === 'NOT_AUTHORIZED') return true;
  const e = (typeof error === 'object' && error !== null ? error : {}) as PgErr;
  if (e.code === 'PGRST202' || e.code === '42883') return true;
  return typeof e.message === 'string' && /could not find the function/i.test(e.message);
}

export function useMyAlerts(plantId: string | undefined) {
  return useQuery({
    queryKey: ['my-alerts', plantId ?? ''],
    enabled: !!plantId,
    queryFn: async (): Promise<AlertsResult> => {
      const { data, error } = await supabase.rpc('get_my_alerts', {
        p_plant_id: plantId ?? '',
        p_limit: 100,
      });
      if (error) {
        if (isUnavailable(error)) return { available: false };
        throw toRpcError(error);
      }
      return { available: true, rows: data ?? [] };
    },
    refetchInterval: LIVE_REFETCH_MS,
  });
}

/** Per user per device: when the Alerts tab last showed the list (ISO time). */
export const SEEN_KEY = 'alerts.seen.v1';

export function readSeen(store: KeyValueStore): string | null {
  const v = store.getItem(SEEN_KEY);
  return v && !Number.isNaN(Date.parse(v)) ? v : null;
}

/**
 * What to remember after the tab showed `rows`: the newest alert's server time (so device clock skew
 * can't hide a newer one), or the device time when there were none. Never moves backwards.
 */
export function seenAfterViewing(
  rows: readonly AlertRow[],
  previous: string | null,
  nowMs: number,
): string {
  const newest = rows.reduce<string | null>(
    (m, r) => (m === null || Date.parse(r.created_at) > Date.parse(m) ? r.created_at : m),
    null,
  );
  const candidate = newest ?? new Date(nowMs).toISOString();
  return previous && Date.parse(previous) > Date.parse(candidate) ? previous : candidate;
}

/**
 * The badge: the caller's alerts since they last opened the Alerts tab (p_since; the server caps it
 * at 7 days), or the last 24 hours if they never did. null when unavailable or on any error.
 * Falls back to the call without p_since while the cloud still has the older function.
 */
export function useMyAlertCount(plantId: string | undefined, userId: string) {
  const since = userId ? readSeen(userStore(userId)) : null;
  return useQuery({
    queryKey: ['my-alert-count', plantId ?? '', since ?? ''],
    enabled: !!plantId && !!userId,
    queryFn: async (): Promise<number | null> => {
      const first = await supabase.rpc('get_my_alert_count', {
        p_plant_id: plantId ?? '',
        ...(since ? { p_since: since } : {}),
      });
      let { data, error } = first;
      if (error && since && isUnavailable(error) && appErrorCode(error) !== 'NOT_AUTHORIZED') {
        ({ data, error } = await supabase.rpc('get_my_alert_count', { p_plant_id: plantId ?? '' }));
      }
      if (error) return null;
      return typeof data === 'number' ? data : null;
    },
    refetchInterval: 60_000,
    retry: false,
  });
}
