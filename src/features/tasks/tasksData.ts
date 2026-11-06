import { useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import type { Database } from '../../types/database';
import { callManageUsers, type Person } from '../admin/manageUsers';
import { unwrap } from '../washroom/rpcError';
import { LIVE_REFETCH_MS } from '../washroom/washroomData';

export type Task = Database['public']['CompositeTypes']['task_result'];

/** Owner: the plant's tasks. Manager: tasks assigned to them. Open first; done in the last 7 days. */
export function useTasks(plantId: string | undefined, includeDone: boolean) {
  return useQuery({
    queryKey: ['tasks', plantId ?? '', includeDone],
    enabled: !!plantId,
    queryFn: async (): Promise<Task[]> =>
      unwrap(
        await supabase.rpc('get_tasks', { p_plant_id: plantId ?? '', p_include_done: includeDone }),
      ) ?? [],
    refetchInterval: LIVE_REFETCH_MS,
  });
}

/** Owner only: the plant's managers by name (from manage-users; never shown to managers). */
export function useManagers(plantId: string | undefined, enabled: boolean) {
  return useQuery({
    queryKey: ['task-managers', plantId ?? ''],
    enabled: enabled && !!plantId,
    queryFn: async (): Promise<{ user_id: string; name: string }[]> => {
      const r = await callManageUsers<{ people: Person[] }>({
        action: 'list',
        plant_id: plantId ?? '',
      });
      return r.people
        .filter((p) => p.memberships.some((m) => m.role === 'manager'))
        .map((p) => ({ user_id: p.user_id, name: p.display_name ?? p.username ?? '?' }))
        .sort((a, b) => a.name.localeCompare(b.name));
    },
    staleTime: 5 * 60_000,
    retry: 1,
  });
}
