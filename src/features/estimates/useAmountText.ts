import { useTranslation } from 'react-i18next';
import { fractionText, pluralCount } from '../washroom/qtyFormat';
import { hoursMinutes } from './estimateMath';

/** Formats amounts ("2½ bins") and washing time ("≈ 4 h 55 min") in the user's language. */
export function useAmountText() {
  const { t, i18n } = useTranslation();
  const nf = new Intl.NumberFormat(i18n.language, { maximumFractionDigits: 2 });
  const fmt = (n: number) => nf.format(n);
  return {
    fmt,
    amount: (qty: number, unit: string) =>
      t(`units.${unit}`, { count: pluralCount(qty), n: fractionText(qty, fmt) }),
    hours: (h: number) => {
      const { h: hh, m } = hoursMinutes(h);
      return hh > 0 ? t('estimates.hoursValue', { h: hh, m }) : t('estimates.minutesValue', { m });
    },
  };
}
