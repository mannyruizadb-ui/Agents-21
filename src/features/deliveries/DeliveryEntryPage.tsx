import { useState, type FormEvent } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useOnline } from '../../lib/useNow';
import { useAmountText } from '../estimates/useAmountText';
import { IconOffline, IconReady, IconWarning } from '../washroom/Icons';
import { WashGroupLabel } from '../washroom/WashGroupLabel';
import { useLocalizedName } from '../washroom/localizedName';
import { errorMessageKey } from '../washroom/rpcError';
import {
  addBins,
  binsToLoads,
  deliveryLines,
  MAX_BINS,
  parseBins,
  type DeliveryLine,
} from './deliveryMath';
import type { PendingDelivery, RecentDelivery } from './deliveryOutbox';
import { groupMapFromLines } from './deliveryVoid';
import { serverNowIso } from './deliveryMath';
import { CancelDelivery } from './CancelDelivery';
import { useCustomers, useCustomerWashGroups, type CustomerGroup } from './deliveriesData';
import { useDeliveryOutbox } from './useDeliveryOutbox';
import '../../lib/forms.css';
import '../washroom/washroom.css';
import '../estimates/estimates.css';
import './deliveries.css';
import { MoreInfo } from '../../lib/MoreInfo';
import { chipCounts, chipsFor, effectiveChip, inChip } from '../estimates/categories';
import { useChip } from '../estimates/useChip';
import { CategoryChips } from '../estimates/CategoryChips';
import { useGroupCategories, useWasherCapacity } from '../estimates/estimatesData';

// Record an outside customer's delivery (owner 2026-11-06 B; first: AA Linen). Owner or manager:
// pick the customer (the only active one is preselected), bins per wash group (steppers −½ / +½ / +1
// since review item 5, typing in quarters still works), an
// optional note, then save (2026-11-07: no entry PIN; the signed-in account is the attribution). Each
// group becomes a queue item at the bottom of the queue. The delivery is stored on the phone
// before the first attempt (client_id made once), so it is never lost offline. Deliveries saved from
// this phone can be cancelled here ("Cancel this delivery"; managers can't list deliveries).
// Review item 5 (owner 2026-11-09): the one place for AA is the Estimates "AA Linen" tab, which embeds
// this form behind "+ AA Linen drop-off" and lists today's drop-offs itself.

const NOTE_MAX = 200;

/**
 * The delivery entry itself, inline in the customer (AA) view of the estimates screen (owner
 * 2026-11-09: "AA right there"; /control/deliveries/new now opens that view). Callers check the owner/manager role first
 * (the outbox and its flusher only run for them).
 */
export function DeliveryEntryForm({
  userId,
  plantId,
  embedded = false,
  onSaved,
}: {
  userId: string;
  plantId: string;
  /**
   * Inside the Estimates AA tab: no heading, outbox notices, saved list or queue link of its own (the
   * tab shows them), and the result goes to `onSaved`.
   */
  embedded?: boolean;
  onSaved?: (m: { kind: 'ok' | 'warn' | 'bad'; text: string }) => void;
}) {
  const { t } = useTranslation();
  const localized = useLocalizedName();
  const { amount, fmt } = useAmountText();

  const customers = useCustomers(plantId);
  const active = (customers.data ?? []).filter((c) => c.active);
  const [pickedCustomer, setPickedCustomer] = useState<string | null>(null);
  const customerId = pickedCustomer ?? active[0]?.id ?? null;
  const customer = active.find((c) => c.id === customerId);
  const groups = useCustomerWashGroups(plantId, customerId);
  const outbox = useDeliveryOutbox(userId);
  // Server clock − device clock (the same reading the estimates use), for the drop-off's time.
  const capacity = useWasherCapacity(plantId);

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
  // The same category chips as the estimates (owner 2026-11-09); counts = groups with bins entered.
  const categories = useGroupCategories(plantId);
  const categoryOf = categories.data ?? new Map();
  const [chipChoice, setChip] = useChip(userId);
  const groupIds = groupList.map((g) => g.id);
  const chips = chipsFor(groupIds, categoryOf);
  const chip = effectiveChip(chipChoice, chips);
  const counts = chipCounts(groupIds, categoryOf, (id) => (bins[id] ?? 0) > 0);
  const shownGroups = groupList.filter((g) => inChip(g.id, chip, categoryOf));

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
      // Server-corrected (like the estimates), so a phone with a wrong clock files it on the right day.
      const at = serverNowIso(Date.now(), capacity.data?.serverOffsetMs);
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
      const m: { kind: 'ok' | 'warn' | 'bad'; text: string } = r.saved
        ? { kind: 'ok', text: t('deliveries.sent') }
        : r.stored
          ? { kind: 'warn', text: t('deliveries.savedOnPhone') }
          : { kind: 'bad', text: t('deliveries.notStored') };
      if (onSaved && (r.saved || r.stored)) onSaved(m);
      else setMessage(m);
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
    <div className={embedded ? 'dl-entry embedded' : 'dl-entry'}>
      {embedded && <h2 className="visually-hidden">{t('deliveries.recordTitle')}</h2>}
      <MoreInfo>{t('deliveries.intro')}</MoreInfo>

      <div role="status" aria-live="polite">
        {message && <MessageLine message={message} />}
      </div>
      {!embedded && (
        <DeliveryOutboxNotices
          userId={userId}
          customerName={customerName}
          linesText={linesText}
          hidePending={message?.kind === 'warn'}
        />
      )}

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
      {active.length === 1 && customer && !embedded && (
        <p className="dl-customer-one">
          {t('deliveries.customerIs', { name: localized(customer.name, customer.name_i18n) })}
        </p>
      )}

      {customerId && (
        <form className="dl-form" onSubmit={onSave} noValidate autoComplete="off">
          <div className="dl-groups-col">
            <CategoryChips chips={chips} value={chip} counts={counts} onChange={setChip} />
            {groups.isPending && <p role="status">{t('common.loading')}</p>}
            {groups.isError && <p className="error">{t(errorMessageKey(groups.error))}</p>}
            {groups.isSuccess && groupList.length === 0 && (
              <p className="notice">{t('deliveries.noGroups')}</p>
            )}
            <ul className="dl-groups">
              {shownGroups.map((g) => (
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
          </div>

          <div className="dl-confirm-col">
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
            </section>
          </div>
        </form>
      )}
      {!embedded && outbox.recent.length > 0 && (
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
      {!embedded && (
        <p>
          <Link to="/control/queue">{t('deliveries.openQueue')}</Link>
        </p>
      )}
    </div>
  );
}

export function MessageLine({
  message,
}: {
  message: { kind: 'ok' | 'warn' | 'bad'; text: string };
}) {
  return (
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
  );
}

/** Deliveries waiting on this phone to send, offline, and refused ones (with Dismiss). */
export function DeliveryOutboxNotices({
  userId,
  customerName,
  linesText,
  hidePending = false,
}: {
  userId: string;
  customerName: (id: string) => string;
  linesText: (ls: DeliveryLine[]) => string;
  /** The caller already says "saved on this phone". */
  hidePending?: boolean;
}) {
  const { t } = useTranslation();
  const online = useOnline();
  const outbox = useDeliveryOutbox(userId);
  return (
    <>
      <div role="status" aria-live="polite">
        {outbox.pending.length > 0 && !hidePending && (
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
          <p>{linesText(r.lines)}</p>
          <button type="button" className="secondary" onClick={() => outbox.dismiss(r.clientId)}>
            {t('station.dismiss')}
          </button>
        </div>
      ))}
    </>
  );
}

/** A delivery saved from this phone, with "Cancel this delivery". */
export function RecentItem({
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

/**
 * One wash group: −½ [number] +½ +1 and the loads it makes (≈), or "loads unknown". AA arrives in whole
 * or half bins (review item 5: 3 bins took 12 taps at ¼); quarters can still be typed.
 */
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
          <WashGroupLabel
            name={group.name}
            nameI18n={group.name_i18n}
            colorHex={group.color_hex}
            colorHex2={group.color_hex_2}
          />
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
          onClick={() => onText(String(addBins(current, -0.5)))}
        >
          −½
        </button>
        <input
          id={id}
          className="mono"
          inputMode="decimal"
          autoComplete="off"
          value={text}
          placeholder="0"
          onFocus={(e) => e.currentTarget.select()}
          onChange={(e) => onText(e.target.value)}
          aria-invalid={bins === null}
          aria-describedby={`${id}-hint`}
        />
        <button
          type="button"
          className="secondary"
          disabled={current >= MAX_BINS}
          onClick={() => onText(String(addBins(current, 0.5)))}
        >
          +½
        </button>
        <button
          type="button"
          className="secondary"
          disabled={current >= MAX_BINS}
          onClick={() => onText(String(addBins(current, 1)))}
        >
          +1
        </button>
      </div>
    </li>
  );
}
