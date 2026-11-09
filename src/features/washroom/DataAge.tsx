import { useTranslation } from 'react-i18next';
import { ageSeconds, freshness } from './washerTime';
import { IconWarning } from './Icons';

/**
 * "Updated 20 s ago" (CLAUDE.md: show data freshness everywhere). Past two refresh periods it adds a
 * warning icon + text, so staleness is never shown by color alone.
 */
export function DataAge({
  updatedAt,
  now,
  isFetching,
  isError,
  refreshSeconds,
  quiet = false,
}: {
  updatedAt: number;
  now: number;
  isFetching?: boolean;
  isError?: boolean;
  /** The query's refetch period (default 30 s): "may be old" after two missed refreshes. */
  refreshSeconds?: number;
  /**
   * Show nothing while the data is fresh and loading fine (a card on a page that already has one
   * freshness line); the warning still shows when this data may be old or failed to refresh.
   */
  quiet?: boolean;
}) {
  const { t } = useTranslation();
  if (!updatedAt) return null;
  const age = ageSeconds(updatedAt, now);
  const band = freshness(age, refreshSeconds);
  if (quiet && band === 'fresh' && !isError) return null;
  const text =
    age < 60
      ? t('washroom.updatedSeconds', { count: age })
      : t('washroom.updatedMinutes', { count: Math.floor(age / 60) });
  return (
    <p className={`data-age data-age-${band}`}>
      {band !== 'fresh' && <IconWarning />}
      <span>{text}</span>
      {band !== 'fresh' && <span> · {t('washroom.mayBeOld')}</span>}
      {isError && <span> · {t('washroom.refreshFailed')}</span>}
      {isFetching && <span className="visually-hidden">{t('washroom.refreshing')}</span>}
    </p>
  );
}
