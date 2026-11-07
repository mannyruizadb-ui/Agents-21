import { useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { unwrap } from '../washroom/rpcError';
import type { AlertMembership } from './alertRecipients';

/** Active memberships of the plant's org, with the alert and load-out flags (read through RLS). */
export function useAlertMemberships(plant: { id: string; org_id: string } | undefined) {
  return useQuery({
    queryKey: ['alert-memberships', plant?.id ?? ''],
    enabled: !!plant,
    queryFn: async (): Promise<AlertMembership[]> =>
      unwrap(
        await supabase
          .from('memberships')
          .select(
            'id, user_id, org_id, plant_id, role, notify_machine_down, notify_washer_idle, can_enter_load_out, alert_levels',
          )
          .eq('org_id', plant?.org_id ?? '')
          .is('revoked_at', null),
      ) ?? [],
  });
}
