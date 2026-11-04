import { useTranslation } from 'react-i18next';
import { IconPin, IconRewash, IconRush } from './Icons';

/** RUSH / Rewash / pinned-to-washer badges: icon + text, never color alone. */
export function QueueBadges({
  rush,
  rewash,
  pinnedTo,
}: {
  rush?: boolean | null;
  rewash?: boolean | null;
  /** Washer name the item is assigned to; `true` = "this washer". */
  pinnedTo?: string | true | null;
}) {
  const { t } = useTranslation();
  return (
    <>
      {rush && (
        <span className="badge badge-rush">
          <IconRush />
          {t('queue.rush')}
        </span>
      )}
      {rewash && (
        <span className="badge badge-rewash">
          <IconRewash />
          {t('queue.rewash')}
        </span>
      )}
      {pinnedTo && (
        <span className="badge badge-pin">
          <IconPin />
          {pinnedTo === true ? t('washroom.pinnedHere') : t('queue.pinnedTo', { washer: pinnedTo })}
        </span>
      )}
    </>
  );
}
