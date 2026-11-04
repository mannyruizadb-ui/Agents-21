import { useTranslation } from 'react-i18next';
import { IconMachineDown } from './Icons';
import { minutesSinceEnd } from './washerTime';

/**
 * "DOWN" notice for a machine: wrench icon + the word DOWN + reason + since when. Never color alone.
 * `serverNowMs` is the server clock estimate (washerTime.estimateServerNow).
 */
export function DownBanner({
  name,
  reason,
  since,
  serverNowMs,
  className = 'down-banner',
}: {
  name?: string;
  reason: string | null | undefined;
  since: string | null | undefined;
  serverNowMs: number;
  className?: string;
}) {
  const { t, i18n } = useTranslation();
  const minutes = minutesSinceEnd(since, serverNowMs);
  const sinceText = since
    ? t('machines.since', {
        time: new Intl.DateTimeFormat(i18n.language, { hour: 'numeric', minute: '2-digit' }).format(
          new Date(since),
        ),
        duration:
          minutes === null
            ? ''
            : minutes < 60
              ? t('machines.minutesShort', { count: minutes })
              : t('machines.hoursShort', { count: Math.floor(minutes / 60), m: minutes % 60 }),
      })
    : '';
  return (
    <div className={className}>
      <p className="down-title">
        <IconMachineDown />
        <strong>{name ? t('machines.isDownNamed', { name }) : t('machines.down')}</strong>
      </p>
      {reason && <p>{t('machines.reasonValue', { reason })}</p>}
      {sinceText && <p>{sinceText}</p>}
    </div>
  );
}
