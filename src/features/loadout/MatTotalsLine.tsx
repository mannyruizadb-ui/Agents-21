import { useTranslation } from 'react-i18next';
import type { MatTotals } from './matTotals';

/** Mats by size and their total ("2×3 4 · 3×5 15 · Total 19"), or "No mats" (entry and board). */
export function MatTotalsLine({ totals }: { totals: MatTotals }) {
  const { t, i18n } = useTranslation();
  const n = (x: number) => new Intl.NumberFormat(i18n.language).format(x);
  if (totals.total === 0) return <p className="lo-mat-totals none">{t('loadOut.mats.none')}</p>;
  return (
    <ul className="lo-mat-totals" aria-label={t('loadOut.mats.bySize')}>
      {totals.bySize.map((s) => (
        <li key={s.size ?? '-'}>
          <span className="lo-mat-size mono">{s.size ?? t('loadOut.mats.noSize')}</span>{' '}
          <strong className="mono">{n(s.pieces)}</strong>
        </li>
      ))}
      <li className="lo-mat-total">
        <span>{t('loadOut.mats.totalWord')}</span>{' '}
        <strong className="mono">{n(totals.total)}</strong>
      </li>
    </ul>
  );
}
