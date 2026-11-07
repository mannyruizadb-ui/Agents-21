import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow } from '../../lib/useNow';
import { useAmountText } from '../estimates/useAmountText';
import { DataAge } from '../washroom/DataAge';
import { IconEdit, IconWarning } from '../washroom/Icons';
import { useLocalizedName } from '../washroom/localizedName';
import { errorMessageKey, unwrap } from '../washroom/rpcError';
import { useMyRoles } from '../washroom/useMyRoles';
import { useAreas, type I18nJson } from '../washroom/washroomData';
import { supabase } from '../../lib/supabase';
import { parseHistoryLines } from './deliveryMath';
import { CancelDelivery } from './CancelDelivery';
import { useCustomerDeliveries, type DeliveryHistoryRow } from './deliveriesData';
import '../../lib/forms.css';
import './deliveries.css';

// Customer deliveries, last 7 days (owner 2026-11-06 B). OWNER ONLY (get_customer_deliveries): when,
// which customer, bins per wash group, and who entered it (owner screens only, never totals by
// person). Managers who open it see only the button to record a delivery. 2026-11-07: the owner can
// cancel a delivery here ("Cancel this delivery", void_customer_delivery).

/** Owner: queue item id → wash group id (owners read every queue item of the plant). */
async function queueItemGroups(ids: string[]): Promise<Map<string, string>> {
  if (ids.length === 0) return new Map();
  const rows =
    unwrap(await supabase.from('queue_items').select('id, wash_group_id').in('id', ids)) ?? [];
  return new Map(rows.flatMap((r) => (r.wash_group_id ? [[r.id, r.wash_group_id] as const] : [])));
}

export function DeliveriesPage() {
  const { t } = useTranslation();
  const session = useRequiredSession();
  const areas = useAreas();
  const plantId = areas.data?.[0]?.plant_id;
  const roles = useMyRoles(session.user.id);
  const mine = roles.rolesFor(plantId);
  const isOwner = mine.has('owner');
  const canRecord = isOwner || mine.has('manager');
  const history = useCustomerDeliveries(plantId, isOwner);
  useLiveRefetch(history.refetch, isOwner && !!plantId);
  const now = useNow(5_000);

  if (!roles.isSuccess || !areas.isSuccess) {
    return (
      <main className="form-page">
        <p role="status">{t('common.loading')}</p>
      </main>
    );
  }

  return (
    <main className="form-page dl-page">
      <h1>{t('deliveries.title')}</h1>
      {canRecord ? (
        <p>
          <Link className="button-link" to="/control/deliveries/new">
            <IconEdit /> {t('deliveries.recordTitle')}
          </Link>
        </p>
      ) : (
        <p className="notice">{t('deliveries.notAllowed')}</p>
      )}
      {isOwner && (
        <section aria-labelledby="dl-history">
          <h2 id="dl-history">{t('deliveries.historyTitle')}</h2>
          {history.dataUpdatedAt > 0 && (
            <DataAge
              updatedAt={history.dataUpdatedAt}
              now={now}
              isFetching={history.isFetching}
              isError={history.isError}
            />
          )}
          {history.isPending && <p role="status">{t('common.loading')}</p>}
          {history.isError && <p className="error">{t(errorMessageKey(history.error))}</p>}
          {history.isSuccess && history.data.length === 0 && (
            <p className="hint">{t('deliveries.none')}</p>
          )}
          <ul className="dl-history">
            {(history.data ?? []).map((d) => (
              <HistoryItem key={d.delivery_id} d={d} />
            ))}
          </ul>
        </section>
      )}
    </main>
  );
}

function HistoryItem({ d }: { d: DeliveryHistoryRow }) {
  const { t, i18n } = useTranslation();
  const localized = useLocalizedName();
  const { amount, fmt } = useAmountText();
  const when = new Date(d.delivered_at);
  const timeText = Number.isNaN(when.getTime())
    ? ''
    : new Intl.DateTimeFormat(i18n.language, {
        weekday: 'short',
        hour: 'numeric',
        minute: '2-digit',
      }).format(when);
  const lines = parseHistoryLines(d.lines);
  return (
    <li className={d.voided ? 'card dl-item voided' : 'card dl-item'}>
      <p className="dl-item-head">
        <strong>{localized(d.customer_name, d.customer_name_i18n as I18nJson)}</strong>{' '}
        <time className="mono" dateTime={d.delivered_at}>
          {timeText}
        </time>
      </p>
      {d.voided && (
        <p className="status-pill warn">
          <IconWarning /> {t('deliveries.voided')}
        </p>
      )}
      {d.voided && d.void_reason && (
        <p className="hint">{t('deliveries.voidReason', { reason: d.void_reason })}</p>
      )}
      <ul className="dl-lines">
        {lines.map((l) => (
          <li key={l.washGroupId}>
            {localized(l.name, l.nameI18n as I18nJson)}: {amount(l.bins, 'bin')}
            {' · '}
            {l.loads !== null
              ? t('deliveries.approxLoads', { count: l.loads <= 1 ? 1 : l.loads, n: fmt(l.loads) })
              : t('deliveries.loadsUnknown')}
          </li>
        ))}
      </ul>
      {d.note && <p className="hint">{t('queue.note', { note: d.note })}</p>}
      {d.entered_by_name && (
        <p className="hint">{t('deliveries.by', { name: d.entered_by_name })}</p>
      )}
      {!d.voided && (
        <CancelDelivery
          deliveryId={d.delivery_id}
          groupsFor={queueItemGroups}
          groupName={(id) => {
            const l = lines.find((x) => x.washGroupId === id);
            return l ? localized(l.name, l.nameI18n as I18nJson) : t('deliveries.cancel.anItem');
          }}
        />
      )}
    </li>
  );
}
