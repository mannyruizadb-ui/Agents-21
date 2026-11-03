import { useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';

export interface OwnerPlant {
  id: string;
  org_id: string;
  name: string;
}

interface MembershipRow {
  org_id: string;
  plant_id: string | null;
  role: string;
}

/**
 * Plants where the signed-in user is an owner (plant-scoped or org-wide membership), read through
 * RLS. This only decides what the UI offers; manage-users re-checks every request on the server.
 */
export function useOwnerPlants(userId: string) {
  return useQuery({
    queryKey: ['owner-plants', userId],
    queryFn: async (): Promise<OwnerPlant[]> => {
      const [memberships, plants] = await Promise.all([
        supabase
          .from('memberships')
          .select('org_id, plant_id, role')
          .eq('user_id', userId)
          .is('revoked_at', null),
        supabase.from('plants').select('id, org_id, name').order('name'),
      ]);
      if (memberships.error) throw memberships.error;
      if (plants.error) throw plants.error;
      const rows = (memberships.data ?? []) as MembershipRow[];
      return ((plants.data ?? []) as OwnerPlant[]).filter((p) =>
        rows.some(
          (m) =>
            m.role === 'owner' &&
            m.org_id === p.org_id &&
            (m.plant_id === null || m.plant_id === p.id),
        ),
      );
    },
  });
}
