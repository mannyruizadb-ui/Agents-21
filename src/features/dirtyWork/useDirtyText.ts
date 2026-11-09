import { useTranslation } from 'react-i18next';
import { fractionText, pluralCount } from '../washroom/qtyFormat';
import { roundedTime, type UnitAmount, type WashTime } from './dirtyWork';

/** Words for the dirty-work numbers, in the user's language. */
export function useDirtyText() {
  const { t, i18n } = useTranslation();
  const nf = new Intl.NumberFormat(i18n.language, { maximumFractionDigits: 2 });
  const fmt = (n: number) => nf.format(n);

  /** "7½ baskets", "2 baskets + 1 load" (units as entered, never added together). */
  const amounts = (list: readonly UnitAmount[]): string =>
    list
      .map((a) => t(`units.${a.unit}`, { count: pluralCount(a.qty), n: fractionText(a.qty, fmt) }))
      .join(' + ');

  /** "≈ 26 loads", "≈ 8+ loads", or "loads unknown" (never "≈ 0" when the number is missing). */
  const loads = (n: number, unknown: number): string => {
    if (unknown > 0 && n === 0) return t('dirty.loadsUnknown');
    return unknown > 0
      ? t('dirty.loadsPlus', { count: n, n: fmt(n) })
      : t('dirty.loads', { count: n, n: fmt(n) });
  };

  /** "1 h 20 min" / "45 min", rounded to 5 min. */
  const duration = (minutes: number): string => {
    const { h, m } = roundedTime(minutes);
    return h > 0 ? t('estimates.hoursValue', { h, m }) : t('estimates.minutesValue', { m });
  };

  /** "≈ 1 h 20 min on 6 washers", or why there is no time. Null when nothing is waiting. */
  const time = (w: WashTime): string | null => {
    if (w.minutes === 0) return null;
    if (w.minutes === null)
      return w.reason === 'noWashers' ? t('estimates.noWashers') : t('estimates.noWashTime');
    return t('dirty.time', { time: duration(w.minutes), count: w.washers });
  };

  return { fmt, amounts, loads, duration, time };
}
