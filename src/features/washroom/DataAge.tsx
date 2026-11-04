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
}: {
  updatedAt: number;
  now: number;
  isFetching?: boolean;
  isError?: boolean;
}) {
  const { t } = useTranslation();
  if (!updatedAt) return null;
  const age = ageSeconds(updatedAt, now);
  const band = freshness(age);
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
