import { IconCustomer } from '../washroom/Icons';
import { useCustomerNameOf } from './useCustomerLookup';

/** "AA Linen" badge (icon + text, never color alone) for a customer's wash group; nothing for ours. */
export function CustomerBadge({ washGroupId }: { washGroupId: string | null | undefined }) {
  const nameOf = useCustomerNameOf();
  const name = nameOf(washGroupId);
  if (!name) return null;
  return (
    <span className="badge badge-customer">
      <IconCustomer />
      {name}
    </span>
  );
}
