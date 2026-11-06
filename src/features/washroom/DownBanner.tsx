import { useTranslation } from 'react-i18next';
import { IconMachineDown } from './Icons';
import { minutesSinceEnd } from './washerTime';
import { reasonText } from './machineReason';
import { useReasonLabeler } from './downReasons';

/**
 * "DOWN" notice for a machine: wrench icon + the word DOWN + reason + since when. Never color alone.
 * `serverNowMs` is the server clock estimate (washerTime.estimateServerNow).
 */
export function DownBanner({
  name,
  reasonCode,
  reasonLabelI18n,
  reason,
  since,
  serverNowMs,
  className = 'down-banner',
}: {
  name?: string;
  /** Preset reason code, shown in the viewer's language. */
  reasonCode?: string | null;
  /** The plant's label for the code (label_i18n), from the board / machine-status RPCs. */
  reasonLabelI18n?: unknown;
  /** Free-text details (or the whole reason, for rows from before reason codes). */
  reason: string | null | undefined;
  since: string | null | undefined;
  serverNowMs: number;
  className?: string;
}) {
  const { t, i18n } = useTranslation();
  const minutes = minutesSinceEnd(since, serverNowMs);
  const labeler = useReasonLabeler();
  const why = reasonText(reasonCode, reason, (c) => labeler(c, reasonLabelI18n));
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
      {why && <p>{t('machines.reasonValue', { reason: why })}</p>}
      {sinceText && <p>{sinceText}</p>}
    </div>
  );
}
