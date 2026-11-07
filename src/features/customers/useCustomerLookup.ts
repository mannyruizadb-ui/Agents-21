import { useQuery } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../lib/supabase';
import { unwrap } from '../washroom/rpcError';
import { useLocalizedName } from '../washroom/localizedName';
import type { I18nJson } from '../washroom/washroomData';
import {
  buildCustomerLookup,
  type CustomerLookup,
  type CustomerNameRow,
  type GroupCustomerRow,
} from './customerLookup';

// Customer tags for wash groups on every screen that shows a group (queue, board, station,
// estimates). Reads every customer wash group the user can see (inactive ones too: history) and the
// customers' names. Customers are owner/manager only; for other roles RLS returns no rows (or the
// read fails) and the tag says "Customer". Cached; many badges share one query.

const NOT_FOUND = (): null => null;

export function useCustomerLookup(): CustomerLookup {
  const groups = useQuery({
    queryKey: ['customer-wash-groups'],
    queryFn: async (): Promise<GroupCustomerRow[]> =>
      unwrap(
        await supabase.from('wash_groups').select('id, customer_id').not('customer_id', 'is', null),
      ) ?? [],
    staleTime: 5 * 60_000,
  });
  const customers = useQuery({
    queryKey: ['customer-names'],
    queryFn: async (): Promise<CustomerNameRow[]> => {
      const res = await supabase.from('customers').select('id, name, name_i18n');
      return res.error ? [] : (res.data ?? []);
    },
    enabled: (groups.data?.length ?? 0) > 0,
    staleTime: 5 * 60_000,
  });
  if (!groups.data || groups.data.length === 0) return NOT_FOUND;
  return buildCustomerLookup(groups.data, customers.data ?? []);
}

/** Text for a group's customer ("AA Linen", or "Customer"), or null for our own goods. */
export function useCustomerNameOf(): (washGroupId: string | null | undefined) => string | null {
  const { t } = useTranslation();
  const lookup = useCustomerLookup();
  const localized = useLocalizedName();
  return (id) => {
    const tag = lookup(id);
    if (!tag) return null;
    return tag.kind === 'named'
      ? localized(tag.name, tag.nameI18n as I18nJson) || t('customers.generic')
      : t('customers.generic');
  };
}
