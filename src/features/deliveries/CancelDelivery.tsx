import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { IconReady, IconWarning } from '../washroom/Icons';
import { errorMessageKey, unwrap } from '../washroom/rpcError';
import { cleanReason, describeVoid, type VoidOutcome } from './deliveryVoid';

// "Cancel this delivery" (owner 2026-11-07): owner or manager, a required short reason, then
// void_customer_delivery. Its queue items that never started are cancelled; items already started stay
// and are listed as "already started — not cancelled". The server decides who may cancel.

const REASON_MAX = 200;

export function CancelDelivery({
  deliveryId,
  groupsFor,
  groupName,
  onVoided,
}: {
  deliveryId: string;
  /** queue item id → wash group id for this delivery's items (may fetch). */
  groupsFor: (queueItemIds: string[]) => Promise<ReadonlyMap<string, string>>;
  groupName: (washGroupId: string) => string;
  onVoided?: (voidedAt: string) => void;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const [asking, setAsking] = useState(false);
  const [reason, setReason] = useState('');
  const [problem, setProblem] = useState<string | null>(null);
  const [outcome, setOutcome] = useState<VoidOutcome | null>(null);
  const fieldId = `dl-void-${deliveryId}`;

  const cancel = useMutation({
    mutationFn: async (why: string) => {
      const r = unwrap(
        await supabase.rpc('void_customer_delivery', {
          p_delivery_id: deliveryId,
          p_reason: why,
        }),
      );
      if (!r) throw new Error('NO_RESULT');
      const ids = [
        ...(r.cancelled_item_ids ?? []),
        ...(Array.isArray(r.kept_items)
          ? r.kept_items.flatMap((k) =>
              k && typeof k === 'object' && !Array.isArray(k) && typeof k.queue_item_id === 'string'
                ? [k.queue_item_id]
                : [],
            )
          : []),
      ];
      const groups = await groupsFor(ids).catch(() => new Map<string, string>());
      return {
        outcome: describeVoid(r, groups),
        voidedAt: r.voided_at ?? new Date().toISOString(),
      };
    },
    onSuccess: ({ outcome: o, voidedAt }) => {
      setOutcome(o);
      setAsking(false);
      setProblem(null);
      onVoided?.(voidedAt);
    },
    onError: (e) => setProblem(t(errorMessageKey(e))),
    onSettled: () => {
      void qc.invalidateQueries({ queryKey: ['queue'] });
      void qc.invalidateQueries({ queryKey: ['customer-deliveries'] });
    },
  });

  function onConfirm() {
    const why = cleanReason(reason);
    if (!why) return setProblem(t('deliveries.cancel.reasonNeeded'));
    setProblem(null);
    cancel.mutate(why);
  }

  const name = (g: string | null) => (g ? groupName(g) : t('deliveries.cancel.anItem'));

  if (outcome) {
    return (
      <div className="dl-cancel-result" role="status" aria-live="polite">
        <p className="notice notice-ok">
          <IconReady />{' '}
          {outcome.duplicate ? t('deliveries.cancel.already') : t('deliveries.cancel.done')}
        </p>
        {outcome.cancelled.length > 0 && (
          <>
            <p>{t('deliveries.cancel.removed', { count: outcome.cancelled.length })}</p>
            <ul className="dl-lines">
              {outcome.cancelled.map((g, i) => (
                <li key={`c-${i}`}>{name(g)}</li>
              ))}
            </ul>
          </>
        )}
        {outcome.kept.length > 0 && (
          <>
            <p className="notice notice-warn">
              <IconWarning /> {t('deliveries.cancel.keptTitle', { count: outcome.kept.length })}
            </p>
            <ul className="dl-lines">
              {outcome.kept.map((k) => (
                <li key={k.queueItemId}>
                  {t('deliveries.cancel.kept', { group: name(k.washGroupId) })}
                </li>
              ))}
            </ul>
          </>
        )}
      </div>
    );
  }

  if (!asking) {
    return (
      <button type="button" className="danger dl-cancel" onClick={() => setAsking(true)}>
        {t('deliveries.cancel.button')}
      </button>
    );
  }

  return (
    <div className="dl-cancel-ask" role="group" aria-labelledby={`${fieldId}-q`}>
      <p id={`${fieldId}-q`}>
        <strong>{t('deliveries.cancel.question')}</strong>
      </p>
      <div className="field">
        <label htmlFor={fieldId}>{t('deliveries.cancel.reasonLabel')}</label>
        <input
          id={fieldId}
          type="text"
          maxLength={REASON_MAX}
          autoComplete="off"
          required
          aria-describedby={`${fieldId}-status`}
          aria-invalid={problem !== null && cleanReason(reason) === null}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
        />
      </div>
      <div className="actions">
        <button type="button" className="danger" disabled={cancel.isPending} onClick={onConfirm}>
          {cancel.isPending ? t('deliveries.cancel.working') : t('deliveries.cancel.confirm')}
        </button>
        <button
          type="button"
          className="secondary"
          onClick={() => {
            setAsking(false);
            setProblem(null);
          }}
        >
          {t('deliveries.cancel.keep')}
        </button>
      </div>
      <p id={`${fieldId}-status`} role="status" aria-live="polite" className="error">
        {problem}
      </p>
    </div>
  );
}
