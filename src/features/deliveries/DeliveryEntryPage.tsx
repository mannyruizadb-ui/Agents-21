import { useState, type FormEvent } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { useOnline } from '../../lib/useNow';
import { useAmountText } from '../estimates/useAmountText';
import { IconOffline, IconReady, IconWarning } from '../washroom/Icons';
import { WashGroupLabel } from '../washroom/WashGroupLabel';
import { useLocalizedName } from '../washroom/localizedName';
import { errorMessageKey } from '../washroom/rpcError';
import { useMyRoles } from '../washroom/useMyRoles';
import { useAreas } from '../washroom/washroomData';
import {
  binsToLoads,
  deliveryLines,
  MAX_BINS,
  parseBins,
  stepBins,
  type DeliveryLine,
} from './deliveryMath';
import type { PendingDelivery, RecentDelivery } from './deliveryOutbox';
import { groupMapFromLines } from './deliveryVoid';
import { CancelDelivery } from './CancelDelivery';
import { useCustomers, useCustomerWashGroups, type CustomerGroup } from './deliveriesData';
import { useDeliveryOutbox } from './useDeliveryOutbox';
import '../../lib/forms.css';
import '../washroom/washroom.css';
import '../estimates/estimates.css';
import './deliveries.css';

// Record an outside customer's delivery (owner 2026-11-06 B; first: AA Linen). Owner or manager:
// pick the customer (the only active one is preselected), bins per wash group in quarters, an
// optional note, then save (2026-11-07: no entry PIN; the signed-in account is the attribution). Each
// group becomes a queue item at the bottom of the queue. The delivery is stored on the phone
// before the first attempt (client_id made once), so it is never lost offline. Deliveries saved from
// this phone can be cancelled here ("Cancel this delivery"; managers can't list deliveries).

const NOTE_MAX = 200;

export function DeliveryEntryPage() {
  const { t } = useTranslation();
  const session = useRequiredSession();
  const areas = useAreas();
  const plantId = areas.data?.[0]?.plant_id;
  const roles = useMyRoles(session.user.id);
  const mine = roles.rolesFor(plantId);

  if (!roles.isSuccess || !areas.isSuccess || !plantId) {
    return (
      <main className="form-page">
        <p role="status">{t('common.loading')}</p>
      </main>
    );
  }
  if (!mine.has('owner') && !mine.has('manager')) {
    return (
      <main className="form-page">
        <h1>{t('deliveries.recordTitle')}</h1>
        <p className="notice">{t('deliveries.notAllowed')}</p>
      </main>
    );
  }
  return <DeliveryEntryScreen userId={session.user.id} plantId={plantId} />;
}

function DeliveryEntryScreen({ userId, plantId }: { userId: string; plantId: string }) {
  const { t } = useTranslation();
  const online = useOnline();
  const localized = useLocalizedName();
  const { amount, fmt } = useAmountText();

  const customers = useCustomers(plantId);
  const active = (customers.data ?? []).filter((c) => c.active);
  const [pickedCustomer, setPickedCustomer] = useState<string | null>(null);
  const customerId = pickedCustomer ?? active[0]?.id ?? null;
  const customer = active.find((c) => c.id === customerId);
  const groups = useCustomerWashGroups(plantId, customerId);
  const outbox = useDeliveryOutbox(userId);

  const [texts, setTexts] = useState<Record<string, string>>({});
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ kind: 'ok' | 'warn' | 'bad'; text: string } | null>(
    null,
  );

  const groupList = groups.data ?? [];
  const bins: Record<string, number> = {};
  const bad: string[] = [];
  for (const g of groupList) {
    const v = parseBins(texts[g.id] ?? '');
    if (v === null) bad.push(g.id);
    else bins[g.id] = v;
  }
  const lines = deliveryLines(
    groupList.map((g) => g.id),
    bins,
  );

  function setText(groupId: string, text: string) {
    setMessage(null);
    setTexts((prev) => ({ ...prev, [groupId]: text }));
  }

  function pickCustomer(id: string) {
    setPickedCustomer(id);
    setTexts({});
    setMessage(null);
  }

  async function onSave(e: FormEvent) {
    e.preventDefault();
    if (!customerId || lines.length === 0 || bad.length > 0) return;
    setBusy(true);
    setMessage(null);
    try {
      const at = new Date().toISOString();
      const delivery: PendingDelivery = {
        clientId: crypto.randomUUID(), // made once, before the first attempt
        plantId,
        customerId,
        lines,
        note: note.trim() === '' ? null : note.trim().slice(0, NOTE_MAX),
        enteredAt: at,
        createdAt: at,
        lastError: null,
      };
      const r = await outbox.submit(delivery);
      if (r.stored || r.saved) {
        setTexts({});
        setNote('');
      }
      setMessage(
        r.saved
          ? { kind: 'ok', text: t('deliveries.sent') }
          : r.stored
            ? { kind: 'warn', text: t('deliveries.savedOnPhone') }
            : { kind: 'bad', text: t('deliveries.notStored') },
      );
    } finally {
      setBusy(false);
    }
  }

  const customerName = (id: string) => {
    const c = customers.data?.find((x) => x.id === id);
    return c ? localized(c.name, c.name_i18n) : t('customers.generic');
  };
  const groupName = (id: string) => {
    const g = groupList.find((x) => x.id === id);
    return g ? localized(g.name, g.name_i18n) : '?';
  };
  const linesText = (ls: DeliveryLine[]) =>
    ls.map((l) => `${groupName(l.washGroupId)} ${amount(l.bins, 'bin')}`).join(', ');

  return (
    <main className="form-page dl-page">
      <h1>{t('deliveries.recordTitle')}</h1>
      <p className="hint">{t('deliveries.intro')}</p>

      <div role="status" aria-live="polite">
        {message && (
          <p className={`notice notice-${message.kind}`}>
            {message.kind === 'ok' ? (
              <IconReady />
            ) : message.kind === 'warn' ? (
              <IconOffline />
            ) : (
              <IconWarning />
            )}{' '}
            {message.text}
          </p>
        )}
        {outbox.pending.length > 0 && !message && (
          <p className="notice notice-warn">
            <IconOffline /> {t('deliveries.waitingToSend', { count: outbox.pending.length })}
          </p>
        )}
      </div>
      {!online && (
        <p className="notice notice-warn">
          <IconOffline /> {t('estimates.offline')}
        </p>
      )}
      {outbox.rejected.map((r) => (
        <div key={r.clientId} className="notice notice-bad" role="alert">
          <p>
            <IconWarning /> {t('deliveries.rejected', { customer: customerName(r.customerId) })}{' '}
            {r.errorCode === 'OUT_OF_RANGE_TIMESTAMP'
              ? t('estimates.errors.tooOld')
              : t(errorMessageKey({ message: r.errorCode }))}
          </p>
          {r.customerId === customerId && <p>{linesText(r.lines)}</p>}
          <button type="button" className="secondary" onClick={() => outbox.dismiss(r.clientId)}>
            {t('station.dismiss')}
          </button>
        </div>
      ))}

      {customers.isPending && <p role="status">{t('common.loading')}</p>}
      {customers.isError && <p className="error">{t(errorMessageKey(customers.error))}</p>}
      {customers.isSuccess && active.length === 0 && (
        <p className="notice">{t('deliveries.noCustomers')}</p>
      )}

      {active.length > 1 && (
        <div className="field" role="radiogroup" aria-labelledby="dl-customer-label">
          <p id="dl-customer-label" className="pick-label">
            {t('deliveries.customerLabel')}
          </p>
          <ul className="pick-list dl-customers">
            {active.map((c) => (
              <li key={c.id}>
                <button
                  type="button"
                  role="radio"
                  aria-checked={c.id === customerId}
                  onClick={() => pickCustomer(c.id)}
                >
                  {localized(c.name, c.name_i18n)}
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
      {active.length === 1 && customer && (
        <p className="dl-customer-one">
          {t('deliveries.customerIs', { name: localized(customer.name, customer.name_i18n) })}
        </p>
      )}

      {customerId && (
        <form onSubmit={onSave} noValidate autoComplete="off">
          {groups.isPending && <p role="status">{t('common.loading')}</p>}
          {groups.isError && <p className="error">{t(errorMessageKey(groups.error))}</p>}
          {groups.isSuccess && groupList.length === 0 && (
            <p className="notice">{t('deliveries.noGroups')}</p>
          )}
          <ul className="dl-groups">
            {groupList.map((g) => (
              <GroupBins
                key={g.id}
                group={g}
                text={texts[g.id] ?? ''}
                bins={bins[g.id] ?? null}
                onText={(v) => setText(g.id, v)}
                fmt={fmt}
              />
            ))}
          </ul>

          <div className="field">
            <label htmlFor="dl-note">{t('deliveries.noteLabel')}</label>
            <textarea
              id="dl-note"
              rows={2}
              maxLength={NOTE_MAX}
              value={note}
              onChange={(e) => setNote(e.target.value)}
            />
          </div>

          <section className="card" aria-labelledby="dl-confirm">
            <h2 id="dl-confirm">{t('deliveries.confirmTitle')}</h2>
            {lines.length === 0 ? (
              <p className="hint">{t('deliveries.nothingYet')}</p>
            ) : (
              <p>
                <strong>{customer ? localized(customer.name, customer.name_i18n) : ''}:</strong>{' '}
                {linesText(lines)}
              </p>
            )}
            {bad.length > 0 && (
              <p className="error">{t('deliveries.fixFirst', { count: bad.length })}</p>
            )}
            <button type="submit" disabled={busy || lines.length === 0 || bad.length > 0}>
              {busy ? t('estimates.saving') : t('deliveries.save')}
            </button>
            <p className="hint">{t('deliveries.goesToQueue')}</p>
          </section>
        </form>
      )}
      {outbox.recent.length > 0 && (
        <section aria-labelledby="dl-recent">
          <h2 id="dl-recent">{t('deliveries.recentTitle')}</h2>
          <ul className="dl-recent">
            {outbox.recent.map((r) => (
              <RecentItem
                key={r.deliveryId}
                r={r}
                customerName={customerName(r.customerId)}
                groupName={groupName}
                linesText={linesText(r.lines)}
                onVoided={(at) => outbox.markVoided(r.deliveryId, at)}
              />
            ))}
          </ul>
        </section>
      )}
      <p>
        <Link to="/control/queue">{t('deliveries.openQueue')}</Link>
      </p>
    </main>
  );
}

/** A delivery saved from this phone, with "Cancel this delivery". */
function RecentItem({
  r,
  customerName,
  groupName,
  linesText,
  onVoided,
}: {
  r: RecentDelivery;
  customerName: string;
  groupName: (id: string) => string;
  linesText: string;
  onVoided: (voidedAt: string) => void;
}) {
  const { t, i18n } = useTranslation();
  // Keeps the cancel result on screen after the phone marks the delivery cancelled.
  const [justVoided, setJustVoided] = useState(false);
  const when = new Date(r.savedAt);
  return (
    <li className={r.voidedAt ? 'card dl-item voided' : 'card dl-item'}>
      <p className="dl-item-head">
        <strong>{customerName}</strong>{' '}
        <time className="mono" dateTime={r.savedAt}>
          {Number.isNaN(when.getTime())
            ? ''
            : new Intl.DateTimeFormat(i18n.language, {
                hour: 'numeric',
                minute: '2-digit',
              }).format(when)}
        </time>
      </p>
      <p className="dl-lines">{linesText}</p>
      {r.voidedAt && !justVoided ? (
        <p className="status-pill warn">
          <IconWarning /> {t('deliveries.cancelled')}
        </p>
      ) : (
        <CancelDelivery
          deliveryId={r.deliveryId}
          groupsFor={async () => groupMapFromLines(r.queueItemIds, r.lines)}
          groupName={groupName}
          onVoided={(at) => {
            setJustVoided(true);
            onVoided(at);
          }}
        />
      )}
    </li>
  );
}

/** One wash group: −¼ [number] +¼ and the loads it makes (≈), or "loads unknown". */
function GroupBins({
  group,
  text,
  bins,
  onText,
  fmt,
}: {
  group: CustomerGroup;
  text: string;
  bins: number | null;
  onText: (text: string) => void;
  fmt: (n: number) => string;
}) {
  const { t } = useTranslation();
  const id = `dl-bins-${group.id}`;
  const current = bins ?? 0;
  const loads = bins !== null && bins > 0 ? binsToLoads(bins, group.loads_per_bin) : null;
  return (
    <li className={current > 0 ? 'dl-group has-bins' : 'dl-group'}>
      <div className="dl-group-label">
        <label htmlFor={id}>
          <WashGroupLabel name={group.name} nameI18n={group.name_i18n} colorHex={group.color_hex} />
        </label>
        <span id={`${id}-hint`} className={bins === null ? 'error' : 'hint'}>
          {bins === null
            ? t('deliveries.badBins', { max: MAX_BINS })
            : current === 0
              ? t('deliveries.binsUnit')
              : loads !== null
                ? t('deliveries.approxLoads', { count: loads <= 1 ? 1 : loads, n: fmt(loads) })
                : t('deliveries.loadsUnknown')}
        </span>
      </div>
      <div className="dl-stepper">
        <button
          type="button"
          className="secondary"
          disabled={current <= 0}
          onClick={() => onText(String(stepBins(current, -1)))}
        >
          −¼
        </button>
        <input
          id={id}
          className="mono"
          inputMode="decimal"
          autoComplete="off"
          value={text}
          placeholder="0"
          onChange={(e) => onText(e.target.value)}
          aria-invalid={bins === null}
          aria-describedby={`${id}-hint`}
        />
        <button
          type="button"
          className="secondary"
          disabled={current >= MAX_BINS}
          onClick={() => onText(String(stepBins(current, 1)))}
        >
          +¼
        </button>
      </div>
    </li>
  );
}
