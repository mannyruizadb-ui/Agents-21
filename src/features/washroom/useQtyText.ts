import { useTranslation } from 'react-i18next';
import type { QtyUnit } from './washroomData';

/**
 * How much work a queue item has left: "3 loads left" when the DB knows the load count; otherwise
 * the quantity in its unit ("40 pieces", approximate items are completed by hand).
 */
export function useQtyText() {
  const { t, i18n } = useTranslation();
  const fmt = new Intl.NumberFormat(i18n.language, { maximumFractionDigits: 2 });
  return (
    loadsRemaining: number | null | undefined,
    qty: number | null | undefined,
    unit: QtyUnit | null | undefined,
  ) => {
    if (loadsRemaining !== null && loadsRemaining !== undefined) {
      return t('washroom.loadsLeft', { count: loadsRemaining, n: fmt.format(loadsRemaining) });
    }
    if (qty === null || qty === undefined || !unit) return '';
    return t(`units.${unit}`, { count: qty, n: fmt.format(qty) });
  };
}
