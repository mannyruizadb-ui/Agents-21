import { useTranslation } from 'react-i18next';
import { fractionText, pluralCount } from './qtyFormat';
import type { QtyUnit } from './washroomData';

/**
 * How much work a queue item has left.
 * - load: "3 loads left" (exact).
 * - basket / bin: "½ bin · ≈ 2 loads left" (the conversion is an owner estimate, so always "≈"),
 *   or "½ bin · no load factor yet" when the group has none (never a guess).
 * - piece / pack: the quantity ("40 pieces"); these are completed by hand.
 */
export function useQtyText() {
  const { t, i18n } = useTranslation();
  const nf = new Intl.NumberFormat(i18n.language, { maximumFractionDigits: 2 });
  const fmt = (n: number) => nf.format(n);
  return (
    loadsRemaining: number | null | undefined,
    qty: number | null | undefined,
    unit: QtyUnit | null | undefined,
  ): string => {
    const has = (v: number | null | undefined): v is number => v !== null && v !== undefined;
    if (!unit || unit === 'load') {
      if (has(loadsRemaining))
        return t('washroom.loadsLeft', { count: loadsRemaining, n: fmt(loadsRemaining) });
      return has(qty)
        ? t('units.load', { count: pluralCount(qty), n: fractionText(qty, fmt) })
        : '';
    }
    if (!has(qty)) return '';
    const amount = t(`units.${unit}`, { count: pluralCount(qty), n: fractionText(qty, fmt) });
    if (unit === 'basket' || unit === 'bin') {
      return has(loadsRemaining)
        ? t('washroom.approxLoadsLeft', { amount, count: loadsRemaining, n: fmt(loadsRemaining) })
        : t('washroom.noLoadFactor', { amount });
    }
    return amount;
  };
}
