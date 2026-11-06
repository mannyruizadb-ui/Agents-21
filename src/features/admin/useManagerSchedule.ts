import { useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { unwrap } from '../washroom/rpcError';

// The plant's shifts and manager shift assignments (the "manager on duty" schedule; owner 2026-11-06).

export interface ShiftOption {
  id: string;
  name: string;
  start_local: string;
  end_local: string;
  days_of_week: number[];
  area_name: string;
}

export interface Assignment {
  id: string;
  membership_id: string;
  shift_id: string;
  active: boolean;
}

export function useShiftOptions(plantId: string | undefined) {
  return useQuery({
    queryKey: ['shift-options', plantId ?? ''],
    enabled: !!plantId,
    queryFn: async (): Promise<ShiftOption[]> => {
      const [shifts, areas] = await Promise.all([
        supabase
          .from('shifts')
          .select('id, name, start_local, end_local, days_of_week, area_id, active')
          .eq('plant_id', plantId ?? '')
          .eq('active', true)
          .order('start_local'),
        supabase
          .from('areas')
          .select('id, name')
          .eq('plant_id', plantId ?? ''),
      ]);
      const names = new Map((unwrap(areas) ?? []).map((a) => [a.id, a.name]));
      return (unwrap(shifts) ?? [])
        .map((s) => ({ ...s, area_name: names.get(s.area_id) ?? '' }))
        .sort(
          (a, b) =>
            a.area_name.localeCompare(b.area_name) || a.start_local.localeCompare(b.start_local),
        );
    },
    staleTime: 5 * 60_000,
  });
}

export function useAssignments(plantId: string | undefined) {
  return useQuery({
    queryKey: ['shift-assignments', plantId ?? ''],
    enabled: !!plantId,
    queryFn: async (): Promise<Assignment[]> =>
      unwrap(
        await supabase
          .from('manager_shift_assignments')
          .select('id, membership_id, shift_id, active')
          .eq('plant_id', plantId ?? ''),
      ) ?? [],
  });
}
