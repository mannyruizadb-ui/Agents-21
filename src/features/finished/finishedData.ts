import { useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { unwrap } from '../washroom/rpcError';
import { LIVE_REFETCH_MS } from '../washroom/washroomData';
import type { FinishItem } from './finishedLogic';
import { parseFgShift, type FgShiftData } from './finishedShift';

// Reads for the finished-goods screen. Server state lives only in TanStack Query (frontend rules).

export const finishedKeys = {
  all: ['finished-goods'] as const,
  shift: (areaId: string) => ['finished-goods', 'shift', areaId] as const,
  items: (plantId: string) => ['finished-goods', 'items', plantId] as const,
};

export { parseFgShift } from './finishedShift';
export type { FgEntry, FgShift, FgShiftData } from './finishedShift';

/** The finishing area's shift and its running lines (live: every 30 s plus useLiveRefetch). */
export function useFinishedShift(areaId: string | undefined) {
  return useQuery({
    queryKey: finishedKeys.shift(areaId ?? ''),
    enabled: !!areaId,
    queryFn: async (): Promise<FgShiftData | null> =>
      parseFgShift(
        unwrap(await supabase.rpc('get_finished_goods_shift', { p_area_id: areaId ?? '' })),
      ),
    refetchInterval: LIVE_REFETCH_MS,
  });
}

const ITEM_COLUMNS =
  'id, name, name_i18n, category, count_mode, pack_size, bin_size, stock_qty, color_hex, sort_order, active, washed';

/** Every item of the plant (the screen picks finishing's; Setup → Items shows all). */
export function usePlantItems(plantId: string | undefined) {
  return useQuery({
    queryKey: finishedKeys.items(plantId ?? ''),
    enabled: !!plantId,
    queryFn: async (): Promise<FinishItem[]> =>
      unwrap(
        await supabase
          .from('item_types')
          .select(ITEM_COLUMNS)
          .eq('plant_id', plantId ?? '')
          .order('sort_order')
          .order('name'),
      ) ?? [],
    staleTime: 5 * 60_000,
  });
}
