import { useQuery } from '@tanstack/react-query';
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

/** The badge: the caller's alerts of the last 24 hours; null when unavailable or on any error. */
export function useMyAlertCount(plantId: string | undefined) {
  return useQuery({
    queryKey: ['my-alert-count', plantId ?? ''],
    enabled: !!plantId,
    queryFn: async (): Promise<number | null> => {
      const { data, error } = await supabase.rpc('get_my_alert_count', {
        p_plant_id: plantId ?? '',
      });
      if (error) return null;
      return typeof data === 'number' ? data : null;
    },
    refetchInterval: 60_000,
    retry: false,
  });
}
