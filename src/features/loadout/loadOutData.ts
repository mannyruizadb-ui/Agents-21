import { useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import type { Database, Json } from '../../types/database';
import { unwrap } from '../washroom/rpcError';
import { LIVE_REFETCH_MS } from '../washroom/washroomData';

// Reads for the load-out (owner 2026-11-06). Who typed or who loaded is never read.

export type RouteRow = Database['public']['Tables']['routes']['Row'];
// entered_by is not readable by clients (column grants), so it is not part of a line here.
export type LineRow = Omit<Database['public']['Tables']['load_out_lines']['Row'], 'entered_by'>;

export interface LoadItem {
  id: string;
  name: string;
  name_i18n: Json;
  count_mode: string;
  pack_size: number | null;
  sort_order: number;
  active: boolean;
}

export interface BoardLine {
  line_id: string;
  item_type_id: string | null;
  item_name: string | null;
  item_name_i18n: Json | null;
  count_mode: string | null;
  pack_size: number | null;
  special_text: string | null;
  qty: number;
  /** owners only (null for everyone else and for lines saved before names were recorded) */
  entered_by_name?: string | null;
}

export interface BoardRoute {
  route_id: string;
  name: string;
  load_time: string;
  loaded: boolean;
  loaded_since: string | null;
  /** owners only */
  loaded_by_name?: string | null;
  lines: BoardLine[];
}

export interface BoardTotal {
  item_type_id: string;
  item_name: string;
  item_name_i18n: Json | null;
  count_mode: string;
  pack_size: number | null;
  qty: number;
}

export interface LoadOutBoard {
  plant_id: string;
  load_date: string;
  routes: BoardRoute[];
  totals: BoardTotal[];
  server_time: string;
}

function isBoard(v: unknown): v is LoadOutBoard {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  return typeof o.load_date === 'string' && Array.isArray(o.routes) && Array.isArray(o.totals);
}

export function useLoadOutBoard(plantId: string | undefined, loadDate?: string) {
  return useQuery({
    queryKey: ['load-out-board', plantId ?? '', loadDate ?? 'next'],
    enabled: !!plantId,
    queryFn: async (): Promise<LoadOutBoard> => {
      const data = unwrap(
        await supabase.rpc('get_load_out_board', {
          p_plant_id: plantId ?? '',
          ...(loadDate ? { p_load_date: loadDate } : {}),
        }),
      );
      if (!isBoard(data)) throw new Error('Unexpected load-out board');
      return data;
    },
    refetchInterval: LIVE_REFETCH_MS,
  });
}

export function useRoutes(plantId: string | undefined) {
  return useQuery({
    queryKey: ['routes', plantId ?? ''],
    enabled: !!plantId,
    queryFn: async (): Promise<RouteRow[]> =>
      unwrap(
        await supabase
          .from('routes')
          .select('*')
          .eq('plant_id', plantId ?? '')
          .order('load_time')
          .order('sort_order'),
      ) ?? [],
    staleTime: 5 * 60_000,
  });
}

/** Active items of the plant, washed or not (soil bags are never washed but go on the load-out). */
export function useLoadItems(plantId: string | undefined) {
  return useQuery({
    queryKey: ['load-items', plantId ?? ''],
    enabled: !!plantId,
    queryFn: async (): Promise<LoadItem[]> =>
      unwrap(
        await supabase
          .from('item_types')
          .select('id, name, name_i18n, count_mode, pack_size, sort_order, active')
          .eq('plant_id', plantId ?? '')
          .eq('active', true)
          .order('sort_order'),
      ) ?? [],
    staleTime: 5 * 60_000,
  });
}

/** Every line (qty 0 included) for one load date, plus the item ids used in the 2 weeks before. */
export function useLoadOutLines(plantId: string | undefined, loadDate: string) {
  return useQuery({
    queryKey: ['load-out-lines', plantId ?? '', loadDate],
    enabled: !!plantId && !!loadDate,
    queryFn: async (): Promise<{ lines: LineRow[]; recentItemIds: Set<string> }> => {
      const from = new Date(`${loadDate}T12:00:00Z`);
      from.setUTCDate(from.getUTCDate() - 14);
      const [day, recent] = await Promise.all([
        supabase
          .from('load_out_lines')
          // Explicit columns: entered_by is hidden by column grants (owner names come from RPCs).
          .select(
            'id, org_id, plant_id, load_date, route_id, item_type_id, special_text, qty, created_at, updated_at',
          )
          .eq('plant_id', plantId ?? '')
          .eq('load_date', loadDate),
        supabase
          .from('load_out_lines')
          .select('item_type_id')
          .eq('plant_id', plantId ?? '')
          .gte('load_date', from.toISOString().slice(0, 10))
          .gt('qty', 0)
          .not('item_type_id', 'is', null),
      ]);
      return {
        lines: unwrap(day) ?? [],
        recentItemIds: new Set(
          (unwrap(recent) ?? []).map((r) => r.item_type_id).filter((x): x is string => !!x),
        ),
      };
    },
  });
}

/** The plant's org and time zone (load times are plant-local). */
export function usePlant(plantId: string | undefined) {
  return useQuery({
    queryKey: ['plant-basics', plantId ?? ''],
    enabled: !!plantId,
    queryFn: async (): Promise<{ id: string; org_id: string; timezone: string } | null> =>
      unwrap(
        await supabase
          .from('plants')
          .select('id, org_id, timezone')
          .eq('id', plantId ?? '')
          .maybeSingle(),
      ),
    staleTime: 60 * 60_000,
  });
}

interface MyMembership {
  id: string;
  role: string;
  plant_id: string | null;
  org_id: string;
  can_enter_load_out: boolean;
}

/**
 * What this account may do on the load-out (UI gating only; every RPC re-checks on the server):
 * enter it (owner, or a manager the owner granted can_enter_load_out) and mark routes loaded (owner,
 * or a manager assigned to a shift that is running now = "manager on duty").
 */
export function useLoadOutPermissions(
  userId: string,
  plant: { id: string; org_id: string } | undefined,
) {
  return useQuery({
    queryKey: ['load-out-perms', userId, plant?.id ?? ''],
    enabled: !!plant,
    refetchInterval: 5 * 60_000,
    queryFn: async () => {
      const ms = (unwrap(
        await supabase
          .from('memberships')
          .select('id, role, plant_id, org_id, can_enter_load_out')
          .eq('user_id', userId)
          .is('revoked_at', null),
      ) ?? []) as MyMembership[];
      const mine = ms.filter(
        (m) => m.org_id === plant?.org_id && (m.plant_id === null || m.plant_id === plant?.id),
      );
      const isOwner = mine.some((m) => m.role === 'owner');
      const managerIds = mine.filter((m) => m.role === 'manager').map((m) => m.id);
      let onDuty = false;
      if (!isOwner && managerIds.length > 0) {
        const assignments =
          unwrap(
            await supabase
              .from('manager_shift_assignments')
              .select('shift_id')
              .in('membership_id', managerIds)
              .eq('active', true),
          ) ?? [];
        const shiftIds = assignments.map((a) => a.shift_id);
        if (shiftIds.length > 0) {
          const now = new Date().toISOString();
          const running =
            unwrap(
              await supabase
                .from('shift_instances')
                .select('id')
                .in('shift_id', shiftIds)
                .lte('starts_at', now)
                .gt('ends_at', now)
                .is('skipped_at', null)
                .limit(1),
            ) ?? [];
          onDuty = running.length > 0;
        }
      }
      return {
        isOwner,
        canEnter: isOwner || mine.some((m) => m.role === 'manager' && m.can_enter_load_out),
        canMarkLoaded: isOwner || onDuty,
        onDuty,
      };
    },
  });
}

export interface MatGroup {
  id: string;
  name: string;
  name_i18n: Json;
  color_hex: string;
  /** A mixed group's second colour (owner 2026-11-10); null = one colour. */
  color_hex_2: string | null;
  sort_order: number;
}

export interface MatItem extends LoadItem {
  wash_group_id: string | null;
}

/**
 * Mats on the load-out (owner 2026-11-09): our active mat basket groups (category 'mats', no customer)
 * and their active mat items. A role that can't read them gets an empty catalog, and mat lines then
 * show as ordinary lines (nothing is hidden).
 */
export function useMatCatalog(plantId: string | undefined) {
  return useQuery({
    queryKey: ['mat-catalog', plantId ?? ''],
    enabled: !!plantId,
    staleTime: 5 * 60_000,
    queryFn: async (): Promise<{ groups: MatGroup[]; items: MatItem[] }> => {
      const groups: MatGroup[] =
        unwrap(
          await supabase
            .from('wash_groups')
            .select('id, name, name_i18n, color_hex, color_hex_2, sort_order')
            .eq('plant_id', plantId ?? '')
            .eq('category', 'mats')
            .eq('active', true)
            .is('customer_id', null)
            .order('sort_order'),
        ) ?? [];
      if (groups.length === 0) return { groups: [], items: [] };
      const items =
        unwrap(
          await supabase
            .from('item_types')
            .select('id, name, name_i18n, count_mode, pack_size, sort_order, active, wash_group_id')
            .eq('plant_id', plantId ?? '')
            .eq('active', true)
            .eq('category', 'mat')
            .in(
              'wash_group_id',
              groups.map((g) => g.id),
            )
            .order('sort_order'),
        ) ?? [];
      return { groups, items };
    },
  });
}
