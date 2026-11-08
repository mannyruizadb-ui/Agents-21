import { useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import type { Database } from '../../types/database';
import { unwrap } from '../washroom/rpcError';

// Reads for customer deliveries (owner 2026-11-06 B). customers: owners and managers read (RLS);
// get_customer_deliveries: owner only, with who entered (owner screens only).

export type CustomerRow = Pick<
  Database['public']['Tables']['customers']['Row'],
  'id' | 'plant_id' | 'name' | 'name_i18n' | 'active' | 'sort_order'
>;

export type CustomerGroup = Pick<
  Database['public']['Tables']['wash_groups']['Row'],
  'id' | 'name' | 'name_i18n' | 'color_hex' | 'loads_per_bin' | 'sort_order'
>;

export type DeliveryHistoryRow =
  Database['public']['Functions']['get_customer_deliveries']['Returns'][number];

export const deliveryKeys = {
  customers: (plantId: string) => ['customers', plantId] as const,
  groups: (customerId: string) => ['customer-groups', customerId] as const,
  history: (plantId: string) => ['customer-deliveries', plantId] as const,
};

/** The plant's customers, active first then by sort order. */
export function useCustomers(plantId: string | undefined) {
  return useQuery({
    queryKey: deliveryKeys.customers(plantId ?? ''),
    enabled: !!plantId,
    queryFn: async (): Promise<CustomerRow[]> =>
      unwrap(
        await supabase
          .from('customers')
          .select('id, plant_id, name, name_i18n, active, sort_order')
          .eq('plant_id', plantId ?? '')
          .order('sort_order')
          .order('name'),
      ) ?? [],
    staleTime: 5 * 60_000,
  });
}

/** A customer's active wash groups, in sort order. */
export function useCustomerWashGroups(plantId: string | undefined, customerId: string | null) {
  return useQuery({
    queryKey: deliveryKeys.groups(customerId ?? ''),
    enabled: !!plantId && !!customerId,
    queryFn: async (): Promise<CustomerGroup[]> =>
      unwrap(
        await supabase
          .from('wash_groups')
          .select('id, name, name_i18n, color_hex, loads_per_bin, sort_order')
          .eq('plant_id', plantId ?? '')
          .eq('customer_id', customerId ?? '')
          .eq('active', true)
          .order('sort_order')
          .order('name'),
      ) ?? [],
    staleTime: 5 * 60_000,
  });
}

/** Owner only: the last 7 days of deliveries (server default window). */
export function useCustomerDeliveries(plantId: string | undefined, enabled: boolean) {
  return useQuery({
    queryKey: deliveryKeys.history(plantId ?? ''),
    enabled: !!plantId && enabled,
    queryFn: async (): Promise<DeliveryHistoryRow[]> =>
      unwrap(await supabase.rpc('get_customer_deliveries', { p_plant_id: plantId ?? '' })) ?? [],
    refetchInterval: 60_000,
  });
}
