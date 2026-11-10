import { useEffect } from 'react';
import { useLocation } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useQueryClient } from '@tanstack/react-query';
import { useRequiredSession } from '../auth/sessionContext';
import { flushEstimates, useEstimateOutbox } from '../../features/estimates/useEstimateOutbox';
import { flushDeliveries, useDeliveryOutbox } from '../../features/deliveries/useDeliveryOutbox';
import { flushFinished, useFinishedOutbox } from '../../features/finished/useFinishedOutbox';
import { useAreas } from '../../features/washroom/washroomData';
import { useMyRoles } from '../../features/washroom/useMyRoles';
import { IconOffline } from '../../features/washroom/Icons';

// App-level sender for the estimate, AA drop-off and finished-goods outboxes (audit 2026-11-10): entries saved
// offline used to send only while their own screen was open. Mounted once in the control layout.
// The ONLY retry loop for both outboxes (the screens' hooks just read them and send on Save), so
// nothing runs twice; flushEstimates/flushDeliveries also share one in-flight promise per account.
// Same role gate as the screens (security review: the outbox flushers run only for owners and
// managers), and only for the signed-in account's own storage.

const RETRY_EVERY_MS = 15_000;

export function OutboxRunner() {
  const session = useRequiredSession();
  const areas = useAreas();
  const plantId = areas.data?.[0]?.plant_id;
  const roles = useMyRoles(session.user.id).rolesFor(plantId);
  if (!plantId || !(roles.has('owner') || roles.has('manager'))) return null;
  return <Runner userId={session.user.id} />;
}

function Runner({ userId }: { userId: string }) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const { pathname } = useLocation();
  const estimates = useEstimateOutbox(userId);
  const deliveries = useDeliveryOutbox(userId);
  const estimateCount = estimates.pending.reduce((n, b) => n + b.entries.length, 0);
  const deliveryCount = deliveries.pending.length;
  const finished = useFinishedOutbox(userId);
  const finishedCount = finished.pending.length;
  const hasPending = estimateCount + deliveryCount + finishedCount > 0;

  // On mount (sign-in, reload), when the device comes back online, and every 15 s while waiting.
  useEffect(() => {
    const run = () => {
      void flushEstimates(userId, qc);
      void flushDeliveries(userId, qc);
      void flushFinished(userId, qc);
    };
    run();
    window.addEventListener('online', run);
    const id = hasPending ? window.setInterval(run, RETRY_EVERY_MS) : undefined;
    return () => {
      window.removeEventListener('online', run);
      if (id !== undefined) window.clearInterval(id);
    };
  }, [userId, qc, hasPending]);

  // The estimates screen (and its AA tab) and the finished-goods screen show their own notices.
  if (
    !hasPending ||
    pathname.startsWith('/control/estimates') ||
    pathname.startsWith('/control/finished')
  )
    return null;
  return (
    <div className="outbox-status" role="status" aria-live="polite">
      {estimateCount > 0 && (
        <p>
          <IconOffline /> {t('estimates.waitingToSend', { count: estimateCount })}
        </p>
      )}
      {deliveryCount > 0 && (
        <p>
          <IconOffline /> {t('deliveries.waitingToSend', { count: deliveryCount })}
        </p>
      )}
      {finishedCount > 0 && (
        <p>
          <IconOffline /> {t('finished.waitingToSend', { count: finishedCount })}
        </p>
      )}
    </div>
  );
}
