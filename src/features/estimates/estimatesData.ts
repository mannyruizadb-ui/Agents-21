import { useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import type { Database } from '../../types/database';
import { unwrap } from '../washroom/rpcError';

// Reads for the estimates screen. No entered-by names are ever selected (owner 2026-11-04).

export type EstimateGroup = Pick<
  Database['public']['Tables']['wash_groups']['Row'],
  | 'id'
  | 'name'
  | 'name_i18n'
  | 'color_hex'
  | 'sort_order'
  | 'allow_basket_estimates'
  | 'allow_bin_estimates'
  | 'loads_per_basket'
  | 'loads_per_bin'
  | 'wash_formula_id'
>;

export interface CurrentEstimate {
  wash_group_id: string;
  qty: number;
  unit: string;
  qty_loads: number | null;
  has_conversion: boolean | null;
  entered_at: string;
  freshness: string | null;
}

export interface StaffOption {
  id: string;
  display_name: string;
}

export const estimateKeys = {
  groups: (plantId: string) => ['estimate-groups', plantId] as const,
  formulas: (plantId: string) => ['wash-formulas', plantId] as const,
  current: (plantId: string) => ['soil', plantId] as const,
  staff: (plantId: string) => ['entry-staff', plantId] as const,
  plant: (plantId: string) => ['plant-settings', plantId] as const,
  capacity: (plantId: string) => ['washer-capacity', plantId] as const,
};

export function useEstimateGroups(plantId: string | undefined) {
  return useQuery({
    queryKey: estimateKeys.groups(plantId ?? ''),
    enabled: !!plantId,
    queryFn: async (): Promise<EstimateGroup[]> =>
      unwrap(
        await supabase
          .from('wash_groups')
          .select(
            'id, name, name_i18n, color_hex, sort_order, allow_basket_estimates, allow_bin_estimates, loads_per_basket, loads_per_bin, wash_formula_id',
          )
          .eq('plant_id', plantId ?? '')
          .eq('active', true)
          .order('sort_order')
          .order('name'),
      ) ?? [],
    staleTime: 5 * 60_000,
  });
}

/** formula id → cycle minutes. */
export function useFormulaMinutes(plantId: string | undefined) {
  return useQuery({
    queryKey: estimateKeys.formulas(plantId ?? ''),
    enabled: !!plantId,
    queryFn: async (): Promise<Map<string, number | null>> => {
      const rows =
        unwrap(
          await supabase
            .from('wash_formulas')
            .select('id, cycle_minutes')
            .eq('plant_id', plantId ?? ''),
        ) ?? [];
      return new Map(rows.map((r) => [r.id, r.cycle_minutes]));
    },
    staleTime: 5 * 60_000,
  });
}

/** Last estimate per wash group (no names). */
export function useCurrentEstimates(plantId: string | undefined) {
  return useQuery({
    queryKey: estimateKeys.current(plantId ?? ''),
    enabled: !!plantId,
    queryFn: async (): Promise<Map<string, CurrentEstimate>> => {
      const rows: CurrentEstimate[] =
        unwrap(
          await supabase
            .from('current_soil_estimates')
            .select('wash_group_id, qty, unit, qty_loads, has_conversion, entered_at, freshness')
            .eq('plant_id', plantId ?? ''),
        ) ?? [];
      return new Map(rows.map((r) => [r.wash_group_id, r]));
    },
    refetchInterval: 60_000,
  });
}

/** People who confirm entries with a PIN (entry_staff_public never exposes the PIN hash). */
export function useEntryStaff(plantId: string | undefined) {
  return useQuery({
    queryKey: estimateKeys.staff(plantId ?? ''),
    enabled: !!plantId,
    queryFn: async (): Promise<StaffOption[]> =>
      unwrap(
        await supabase
          .from('entry_staff_public')
          .select('id, display_name')
          .eq('plant_id', plantId ?? '')
          .eq('active', true)
          .eq('has_pin', true)
          .order('display_name'),
      ) ?? [],
    staleTime: 5 * 60_000,
  });
}

/** The plant's PIN reuse window in minutes (0 = a PIN on every save). */
export function usePinReuseMinutes(plantId: string | undefined) {
  return useQuery({
    queryKey: estimateKeys.plant(plantId ?? ''),
    enabled: !!plantId,
    queryFn: async (): Promise<number> => {
      const row = unwrap(
        await supabase
          .from('plants')
          .select('staff_pin_reuse_minutes')
          .eq('id', plantId ?? '')
          .maybeSingle(),
      );
      return row?.staff_pin_reuse_minutes ?? 0;
    },
    staleTime: 5 * 60_000,
  });
}

/**
 * Washing capacity right now: the sum of load factors of active washers that are not down
 * (Washer 6 counts 1.19). Down status comes from get_machine_status.
 */
export function useWasherCapacity(plantId: string | undefined) {
  return useQuery({
    queryKey: estimateKeys.capacity(plantId ?? ''),
    enabled: !!plantId,
    queryFn: async (): Promise<{ washers: number; capacity: number; serverOffsetMs: number }> => {
      const [machines, status] = await Promise.all([
        supabase
          .from('machines')
          .select('id, load_factor')
          .eq('plant_id', plantId ?? '')
          .eq('kind', 'washer')
          .eq('active', true),
        supabase.rpc('get_machine_status', { p_plant_id: plantId ?? '' }),
      ]);
      const down = new Set(
        (unwrap(status) ?? []).filter((m) => m.status === 'down').map((m) => m.machine_id),
      );
      const up = (unwrap(machines) ?? []).filter((m) => !down.has(m.id));
      const serverTime = Date.parse(unwrap(status)?.[0]?.server_time ?? '');
      return {
        // server clock − device clock, so entry times sent as p_entered_at use the server's clock
        serverOffsetMs: Number.isNaN(serverTime) ? 0 : serverTime - Date.now(),
        washers: up.length,
        capacity: up.reduce((sum, m) => sum + Number(m.load_factor ?? 1), 0),
      };
    },
    refetchInterval: 60_000,
  });
}
