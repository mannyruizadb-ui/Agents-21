import { useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import type { Database } from '../../types/database';
import { unwrap } from './rpcError';

// Reads for the washroom screens. Server state lives only in TanStack Query (frontend rules).

export type QtyUnit = Database['public']['Tables']['queue_items']['Row']['unit'];
export type I18nJson = Database['public']['Tables']['wash_groups']['Row']['name_i18n'];

/**
 * One row of get_washroom_board. The generated types mark every column non-null, but the SQL
 * returns nulls for an idle washer (no cycle) and for an empty queue (no NEXT), so they are
 * nullable here.
 */
export interface WasherBoardRow {
  machine_id: string;
  machine_name: string;
  load_factor: number | null;
  status: string;
  cycle_id: string | null;
  wash_group_id: string | null;
  wash_group_name: string | null;
  wash_group_name_i18n: I18nJson | null;
  wash_group_color_hex: string | null;
  is_rewash: boolean | null;
  wash_formula_id: string | null;
  formula_external_no: string | null;
  formula_name: string | null;
  cycle_minutes: number | null;
  started_at: string | null;
  expected_end_at: string | null;
  minutes_since_start: number | null;
  minutes_ready: number | null;
  queue_item_id: string | null;
  next_queue_item_id: string | null;
  next_is_assigned: boolean | null;
  next_wash_group_id: string | null;
  next_wash_group_name: string | null;
  next_wash_group_name_i18n: I18nJson | null;
  next_wash_group_color_hex: string | null;
  next_item_type_id: string | null;
  next_item_name: string | null;
  next_item_name_i18n: I18nJson | null;
  next_qty: number | null;
  next_unit: QtyUnit | null;
  next_is_rush: boolean | null;
  next_is_rewash: boolean | null;
  next_loads_remaining: number | null;
  next_version: number | null;
  server_time: string;
}

export interface AreaRow {
  id: string;
  plant_id: string;
  name: string;
  kind: Database['public']['Tables']['areas']['Row']['kind'];
}

export interface WashGroupRow {
  id: string;
  plant_id: string;
  name: string;
  name_i18n: I18nJson;
  color_hex: string;
}

export interface WasherRow {
  id: string;
  plant_id: string;
  area_id: string;
  name: string;
}

/** Live boards refetch this often (and on focus, online, visibilitychange). */
export const LIVE_REFETCH_MS = 30_000;

export const washroomKeys = {
  areas: ['areas'] as const,
  board: (areaId: string) => ['washroom-board', areaId] as const,
  queue: (areaId: string) => ['queue', areaId] as const,
  washGroups: (plantId: string) => ['wash-groups', plantId] as const,
  washers: (areaId: string) => ['washers', areaId] as const,
  machine: (machineId: string) => ['machine', machineId] as const,
};

/** Active areas the user can see (RLS), in plant order. */
export function useAreas() {
  return useQuery({
    queryKey: washroomKeys.areas,
    queryFn: async (): Promise<AreaRow[]> =>
      unwrap(
        await supabase
          .from('areas')
          .select('id, plant_id, name, kind')
          .eq('active', true)
          .order('sort_order')
          .order('name'),
      ) ?? [],
    staleTime: 5 * 60_000,
  });
}

export function useWashroomBoard(areaId: string | undefined) {
  return useQuery({
    queryKey: washroomKeys.board(areaId ?? ''),
    enabled: !!areaId,
    queryFn: async (): Promise<WasherBoardRow[]> => {
      const rows: WasherBoardRow[] =
        unwrap(await supabase.rpc('get_washroom_board', { p_area_id: areaId ?? '' })) ?? [];
      return rows;
    },
    refetchInterval: LIVE_REFETCH_MS,
  });
}

/** Active wash groups of a plant, in setup order. */
export function useWashGroups(plantId: string | undefined) {
  return useQuery({
    queryKey: washroomKeys.washGroups(plantId ?? ''),
    enabled: !!plantId,
    queryFn: async (): Promise<WashGroupRow[]> =>
      unwrap(
        await supabase
          .from('wash_groups')
          .select('id, plant_id, name, name_i18n, color_hex')
          .eq('plant_id', plantId ?? '')
          .eq('active', true)
          .order('sort_order')
          .order('name'),
      ) ?? [],
    staleTime: 5 * 60_000,
  });
}

/** Active washers of an area (inactive ones are hidden: CLAUDE.md M2 notes). */
export function useWashers(areaId: string | undefined) {
  return useQuery({
    queryKey: washroomKeys.washers(areaId ?? ''),
    enabled: !!areaId,
    queryFn: async (): Promise<WasherRow[]> =>
      unwrap(
        await supabase
          .from('machines')
          .select('id, plant_id, area_id, name')
          .eq('area_id', areaId ?? '')
          .eq('kind', 'washer')
          .eq('active', true)
          .order('name'),
      ) ?? [],
    staleTime: 5 * 60_000,
  });
}

/** One machine by id (the station screen's washer). null = not found or not visible. */
export function useMachine(machineId: string | undefined) {
  return useQuery({
    queryKey: washroomKeys.machine(machineId ?? ''),
    enabled: !!machineId,
    queryFn: async () =>
      unwrap(
        await supabase
          .from('machines')
          .select('id, plant_id, area_id, name, kind, active')
          .eq('id', machineId ?? '')
          .maybeSingle(),
      ),
    staleTime: 5 * 60_000,
  });
}

/** The first area of a kind, or the one chosen by id. */
export function pickArea(
  areas: readonly AreaRow[] | undefined,
  kind: AreaRow['kind'],
  chosenId?: string | null,
): AreaRow | undefined {
  if (!areas) return undefined;
  return areas.find((a) => a.id === chosenId) ?? areas.find((a) => a.kind === kind);
}
