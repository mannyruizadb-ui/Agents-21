import { useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { unwrap } from './rpcError';
import { rolesOnPlant, type MemberRole } from './plantRoles';

/**
 * The signed-in user's roles per plant, read through RLS. Decides only what the UI offers; the
 * server checks the role on every write.
 */
export function useMyRoles(userId: string) {
  const query = useQuery({
    queryKey: ['my-roles', userId],
    queryFn: async () => {
      const [memberships, plants] = await Promise.all([
        supabase
          .from('memberships')
          .select('org_id, plant_id, role')
          .eq('user_id', userId)
          .is('revoked_at', null),
        supabase.from('plants').select('id, org_id'),
      ]);
      return {
        memberships: unwrap(memberships) ?? [],
        plants: unwrap(plants) ?? [],
      };
    },
    staleTime: 5 * 60_000,
  });
  const rolesFor = (plantId: string | undefined): Set<MemberRole> =>
    rolesOnPlant(
      query.data?.memberships ?? [],
      query.data?.plants.find((p) => p.id === plantId),
    );
  return { ...query, rolesFor };
}
