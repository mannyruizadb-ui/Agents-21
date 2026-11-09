import { useId } from 'react';
import { useTranslation } from 'react-i18next';
import { IconWarning } from './Icons';
import { OFF_QUEUE_REASONS, type OffQueueReason } from './offQueue';

// One-tap "why not the queue's next?" (owner 2026-11-09): four big buttons, then the start goes
// ahead. The reason is about the load, never the person (taps stay anonymous).

export function OffQueueReasonPicker({
  question,
  onPick,
  onCancel,
}: {
  question: string;
  onPick: (reason: OffQueueReason) => void;
  onCancel: () => void;
}) {
  const { t } = useTranslation();
  const id = useId();
  return (
    <div className="confirm-box station-message warn reason-box" role="group" aria-labelledby={id}>
      <p id={id} className="reason-q">
        <IconWarning />
        <strong>{question}</strong>
      </p>
      <div className="reason-grid">
        {OFF_QUEUE_REASONS.map((r) => (
          <button key={r} type="button" className="reason-button" onClick={() => onPick(r)}>
            {t(`offQueue.reason.${r}`)}
          </button>
        ))}
      </div>
      <button type="button" onClick={onCancel}>
        {t('common.cancel')}
      </button>
    </div>
  );
}
