import { useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { unwrap } from '../washroom/rpcError';
import type { FinishedInput, OffQueueInput, PaceInput } from './dashboardLogic';

// Owner-only reads for the Home dashboard (owner 2026-11-09). Both RPCs check the owner role first
// and default to the CURRENT production day (plants.production_day_start, 12:00 → 12:00 plant-local),
// so the client never computes the date. Entered-by names are never selected or shown.

export const DASHBOARD_REFETCH_MS = 60_000;

export const dashboardKeys = {
  pace: (plantId: string) => ['wash-group-pace', plantId, 'today'] as const,
  finished: (plantId: string) => ['finished-goods-entries', plantId, 'today'] as const,
  offQueue: (plantId: string) => ['off-queue-starts', plantId, 'today'] as const,
};

/** Loads washed per wash group this production day (get_wash_group_pace; owner only). */
export function useLoadsToday(plantId: string | undefined, enabled: boolean) {
  return useQuery({
    queryKey: dashboardKeys.pace(plantId ?? ''),
    enabled: !!plantId && enabled,
    queryFn: async (): Promise<PaceInput[]> =>
      unwrap(await supabase.rpc('get_wash_group_pace', { p_plant_id: plantId ?? '' })) ?? [],
    refetchInterval: DASHBOARD_REFETCH_MS,
  });
}

/** Finished-goods entries this production day (owner only). Only the columns for totals are kept. */
export function useFinishedToday(plantId: string | undefined, enabled: boolean) {
  return useQuery({
    queryKey: dashboardKeys.finished(plantId ?? ''),
    enabled: !!plantId && enabled,
    queryFn: async (): Promise<FinishedInput[]> => {
      const rows =
        unwrap(
          await supabase.rpc('get_finished_goods_entries', {
            p_plant_id: plantId ?? '',
            p_limit: 500,
          }),
        ) ?? [];
      // Drop who-entered / who-voided: no names on the dashboard, no per-person totals.
      return rows.map((r) => ({
        item_type_id: r.item_type_id,
        item_name: r.item_name,
        item_name_i18n: r.item_name_i18n,
        pieces: r.pieces,
        voided_at: r.voided_at,
      }));
    },
    refetchInterval: DASHBOARD_REFETCH_MS,
  });
}

/** Off-queue washer starts this production day, by reason (get_off_queue_starts; owner only). */
export function useOffQueueToday(plantId: string | undefined, enabled: boolean) {
  return useQuery({
    queryKey: dashboardKeys.offQueue(plantId ?? ''),
    enabled: !!plantId && enabled,
    queryFn: async (): Promise<OffQueueInput[]> =>
      (unwrap(await supabase.rpc('get_off_queue_starts', { p_plant_id: plantId ?? '' })) ?? []).map(
        (r) => ({ reason: r.reason, starts: r.starts, last_at: r.last_at }),
      ),
    refetchInterval: DASHBOARD_REFETCH_MS,
  });
}
