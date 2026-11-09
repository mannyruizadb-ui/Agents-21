import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow } from '../../lib/useNow';
import { useAmountText } from '../estimates/useAmountText';
import { CustomerWaiting } from '../dirtyWork/DirtyWorkSummary';
import type { useDirtyWork } from '../dirtyWork/useDirtyWork';
import { usePlant } from '../loadout/loadOutData';
import { DataAge } from '../washroom/DataAge';
import { IconCustomer } from '../washroom/Icons';
import { useLocalizedName } from '../washroom/localizedName';
import { errorMessageKey } from '../washroom/rpcError';
import { HistoryItem } from './DeliveriesPage';
import {
  DeliveryEntryForm,
  DeliveryOutboxNotices,
  MessageLine,
  RecentItem,
} from './DeliveryEntryPage';
import { isPlantToday, plantDayStartIso, type DeliveryLine } from './deliveryMath';
import {
  useCustomerDeliveries,
  useCustomers,
  useCustomerWashGroups,
  type CustomerRow,
} from './deliveriesData';
import { useDeliveryOutbox } from './useDeliveryOutbox';
import './deliveries.css';

// The Estimates "AA Linen" tab (review item 5, owner 2026-11-09: "AA in one place"). Top: what AA has
// waiting now (the shared dirty-work selector, so it agrees with Home). Then one big "+ AA Linen
// drop-off" button that opens the drop-off form, and today's drop-offs with "Cancel this delivery":
// the owner reads them all (get_customer_deliveries, owner only); a manager can't read the delivery
// history, so a manager sees the ones saved on this phone today. Nothing here names a person except
// the owner's own history line ("by …", owner screens only).

type Msg = { kind: 'ok' | 'warn' | 'bad'; text: string };

export function AaDropOffView({
  userId,
  plantId,
  isOwner,
  dirty,
  customer,
  startOpen,
}: {
  userId: string;
  plantId: string;
  isOwner: boolean;
  dirty: ReturnType<typeof useDirtyWork>;
  /** The one active customer; undefined when several are active (the form then asks which). */
  customer: CustomerRow | undefined;
  /** Open the form at once (old /control/deliveries/new links). */
  startOpen: boolean;
}) {
  const { t } = useTranslation();
  const localized = useLocalizedName();
  const [open, setOpen] = useState(startOpen);
  const [message, setMessage] = useState<Msg | null>(null);
  const toggleRef = useRef<HTMLButtonElement>(null);
  const formRef = useRef<HTMLDivElement>(null);
  const name = customer ? localized(customer.name, customer.name_i18n) : null;
  const label = name ? t('dirty.dropOffTab', { name }) : t('deliveries.dropOffAny');

  useEffect(() => {
    if (open) formRef.current?.querySelector<HTMLElement>('input, button')?.focus();
  }, [open]);

  return (
    <div className="aa-view">
      <div className="aa-waiting">
        <CustomerWaiting
          dirty={dirty}
          headingId="aa-waiting"
          only={customer?.id}
          titleKey="dirty.customerNow"
          level={2}
        />
        {!dirty.queueReady && <p role="status">{t('common.loading')}</p>}
      </div>

      <div className="aa-status">
        <div role="status" aria-live="polite">
          {message && <MessageLine message={message} />}
        </div>
        <DeliveryOutboxNoticesFor
          userId={userId}
          plantId={plantId}
          hidePending={message?.kind === 'warn'}
        />
      </div>

      <button
        ref={toggleRef}
        type="button"
        className={open ? 'aa-add secondary' : 'aa-add'}
        aria-expanded={open}
        aria-controls="aa-form"
        onClick={() => {
          setMessage(null);
          setOpen((v) => !v);
        }}
      >
        {open ? (
          t('deliveries.closeForm')
        ) : (
          <>
            <span aria-hidden="true" className="aa-plus">
              +
            </span>{' '}
            {label}
          </>
        )}
      </button>

      {open && (
        <div id="aa-form" ref={formRef} className="aa-form card">
          <h2 className="aa-form-title">{label}</h2>
          <DeliveryEntryForm
            userId={userId}
            plantId={plantId}
            embedded
            onSaved={(m) => {
              setMessage(m);
              setOpen(false);
              toggleRef.current?.focus();
            }}
          />
        </div>
      )}

      <TodaysDropOffs userId={userId} plantId={plantId} isOwner={isOwner} />
    </div>
  );
}

/** The outbox notices need group names for refused deliveries' lines. */
function DeliveryOutboxNoticesFor({
  userId,
  plantId,
  hidePending,
}: {
  userId: string;
  plantId: string;
  hidePending: boolean;
}) {
  const { t } = useTranslation();
  const { names } = useCustomerNames(plantId);
  return (
    <DeliveryOutboxNotices
      userId={userId}
      customerName={(id) => names.customer(id) ?? t('customers.generic')}
      linesText={names.lines}
      hidePending={hidePending}
    />
  );
}

/** Customer and wash-group names for the drop-offs listed here. */
function useCustomerNames(plantId: string) {
  const { t } = useTranslation();
  const localized = useLocalizedName();
  const { amount } = useAmountText();
  const customers = useCustomers(plantId);
  const active = (customers.data ?? []).filter((c) => c.active);
  // Group names: the first active customer's groups (AA Linen is the only one today); a group of
  // another customer reads "?" rather than guessing.
  const groups = useCustomerWashGroups(plantId, active[0]?.id ?? null);
  const group = (id: string) => {
    const g = groups.data?.find((x) => x.id === id);
    return g ? localized(g.name, g.name_i18n) : t('deliveries.cancel.anItem');
  };
  const customer = (id: string) => {
    const c = customers.data?.find((x) => x.id === id);
    return c ? localized(c.name, c.name_i18n) : null;
  };
  return {
    names: {
      customer,
      group,
      lines: (ls: DeliveryLine[]) =>
        ls.map((l) => `${group(l.washGroupId)} ${amount(l.bins, 'bin')}`).join(', '),
    },
  };
}

function TodaysDropOffs({
  userId,
  plantId,
  isOwner,
}: {
  userId: string;
  plantId: string;
  isOwner: boolean;
}) {
  const { t } = useTranslation();
  const now = useNow(60_000);
  const plant = usePlant(plantId);
  const tz = plant.data?.timezone ?? 'America/New_York';
  // The plant day's start changes only at midnight, so the query key stays put all day.
  const since = plantDayStartIso(now, tz);
  const history = useCustomerDeliveries(plantId, isOwner && plant.isSuccess, since);
  useLiveRefetch(history.refetch, isOwner && plant.isSuccess);
  const outbox = useDeliveryOutbox(userId);
  const { names } = useCustomerNames(plantId);
  const mine = outbox.recent.filter(
    (r) => r.plantId === plantId && isPlantToday(r.savedAt, now, tz),
  );

  return (
    <section className="aa-today" aria-labelledby="aa-today-title">
      <div className="aa-today-head">
        <h2 id="aa-today-title">{t('deliveries.todayTitle')}</h2>
        {isOwner && (
          <Link to="/control/deliveries" className="dash-link">
            {t('deliveries.historyLink')} <span aria-hidden="true">›</span>
          </Link>
        )}
      </div>
      {isOwner ? (
        <>
          {history.dataUpdatedAt > 0 && (
            <DataAge
              quiet
              updatedAt={history.dataUpdatedAt}
              now={now}
              isFetching={history.isFetching}
              isError={history.isError}
            />
          )}
          {history.isPending && <p role="status">{t('common.loading')}</p>}
          {history.isError && <p className="error">{t(errorMessageKey(history.error))}</p>}
          {history.isSuccess && history.data.length === 0 && (
            <p className="hint">
              <IconCustomer /> {t('deliveries.noneToday')}
            </p>
          )}
          <ul className="dl-history">
            {(history.data ?? []).map((d) => (
              <HistoryItem key={d.delivery_id} d={d} />
            ))}
          </ul>
        </>
      ) : (
        <>
          <p className="hint">{t('deliveries.todayManagerHint')}</p>
          {mine.length === 0 ? (
            <p className="hint">
              <IconCustomer /> {t('deliveries.noneTodayPhone')}
            </p>
          ) : (
            <ul className="dl-recent">
              {mine.map((r) => (
                <RecentItem
                  key={r.deliveryId}
                  r={r}
                  customerName={names.customer(r.customerId) ?? t('customers.generic')}
                  groupName={names.group}
                  linesText={names.lines(r.lines)}
                  onVoided={(at) => outbox.markVoided(r.deliveryId, at)}
                />
              ))}
            </ul>
          )}
        </>
      )}
    </section>
  );
}
