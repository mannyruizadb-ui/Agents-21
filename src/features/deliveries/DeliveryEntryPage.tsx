import { useState, type FormEvent } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { userStore } from '../../lib/scopedStore';
import { useNow, useOnline } from '../../lib/useNow';
import { PinInput, RePin } from '../estimates/PinInput';
import { useEntryStaff, usePinReuseMinutes } from '../estimates/estimatesData';
import { readSession, rememberSession, sessionEnd, validSession } from '../estimates/sessionCache';
import {
  LAST_STAFF_KEY,
  readLastStaff,
  startSessionDetailed,
} from '../estimates/useEstimateOutbox';
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
import type { PendingDelivery } from './deliveryOutbox';
import { useCustomers, useCustomerWashGroups, type CustomerGroup } from './deliveriesData';
import { useDeliveryOutbox } from './useDeliveryOutbox';
import '../../lib/forms.css';
import '../washroom/washroom.css';
import '../estimates/estimates.css';
import './deliveries.css';

// Record an outside customer's delivery (owner 2026-11-06 B; first: AA Linen). Owner or manager:
// pick the customer (the only active one is preselected), bins per wash group in quarters, an
// optional note, then name + PIN (the same staff session and 10-minute reuse as estimates). Each
// group becomes a queue item at the bottom of the queue. The delivery is stored on the phone
// before the first attempt (client_id made once), so it is never lost offline.

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
  const now = useNow(15_000);
  const online = useOnline();
  const localized = useLocalizedName();
  const { amount, fmt } = useAmountText();

  const customers = useCustomers(plantId);
  const active = (customers.data ?? []).filter((c) => c.active);
  const [pickedCustomer, setPickedCustomer] = useState<string | null>(null);
  const customerId = pickedCustomer ?? active[0]?.id ?? null;
  const customer = active.find((c) => c.id === customerId);
  const groups = useCustomerWashGroups(plantId, customerId);
  const staff = useEntryStaff(plantId);
  const reuse = usePinReuseMinutes(plantId);
  const reuseMinutes = reuse.data ?? 0;
  const outbox = useDeliveryOutbox(userId, reuseMinutes);

  const [texts, setTexts] = useState<Record<string, string>>({});
  const [note, setNote] = useState('');
  const [staffId, setStaffId] = useState(() => readLastStaff(userId));
  const [pin, setPin] = useState('');
  const [usePinAnyway, setUsePinAnyway] = useState(false);
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
  const cached = validSession(readSession(userStore(userId)), now, {
    userId,
    plantId,
    staffId: staffId || null,
  });
  const needPin = !cached || usePinAnyway;
  const staffName = staff.data?.find((s) => s.id === staffId)?.display_name;

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
    if (!staffId) return setMessage({ kind: 'bad', text: t('estimates.errors.who') });
    if (needPin && !/^\d{4}$/.test(pin)) {
      return setMessage({ kind: 'bad', text: t('estimates.errors.pin') });
    }
    setBusy(true);
    setMessage(null);
    try {
      let sessionId = needPin ? null : (cached?.sessionId ?? null);
      if (needPin) {
        // Check the PIN now when online, so a typo is caught here and nothing is stored with it.
        const s = await startSessionDetailed(staffId, pin);
        if (s.kind === 'pin') {
          setMessage({
            kind: 'bad',
            text:
              s.error === 'STAFF_LOCKED'
                ? t('estimates.errors.locked')
                : t('estimates.errors.wrongPin'),
          });
          return;
        }
        if (s.kind === 'rejected') {
          setMessage({ kind: 'bad', text: t(errorMessageKey({ message: s.errorCode })) });
          return;
        }
        if (s.kind === 'ok') {
          sessionId = s.sessionId;
          const end = sessionEnd(s.expiresAt, Date.now(), reuseMinutes);
          if (end !== null) {
            rememberSession(userStore(userId), {
              userId,
              plantId,
              staffId,
              sessionId: s.sessionId,
              expiresAt: end,
            });
          }
        }
        // s.kind === 'retry': offline. Stored with the PIN; a session opens when it sends.
      }
      const at = new Date().toISOString();
      const delivery: PendingDelivery = {
        clientId: crypto.randomUUID(), // made once, before the first attempt
        plantId,
        customerId,
        lines,
        note: note.trim() === '' ? null : note.trim().slice(0, NOTE_MAX),
        enteredAt: at,
        staffId,
        pin: needPin ? pin : '',
        sessionId,
        createdAt: at,
        lastError: null,
      };
      try {
        userStore(userId).setItem(LAST_STAFF_KEY, staffId);
      } catch {
        // not remembered; chosen again next time
      }
      const r = await outbox.submit(delivery);
      setPin('');
      setUsePinAnyway(false);
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
      {outbox.needsPin && <RePin staffId={outbox.needsPin.staffId} onPin={outbox.retryWithPin} />}
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
            <div className="field">
              <label htmlFor="dl-who">{t('estimates.whoLabel')}</label>
              <select id="dl-who" value={staffId} onChange={(e) => setStaffId(e.target.value)}>
                <option value="">{t('queue.choose')}</option>
                {(staff.data ?? []).map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.display_name}
                  </option>
                ))}
              </select>
              {staff.data && staff.data.length === 0 && (
                <p className="hint">{t('estimates.noStaff')}</p>
              )}
            </div>
            {cached && !usePinAnyway ? (
              <p className="hint">
                {t('estimates.pinStillGood', {
                  name: staffName ?? '',
                  count: Math.max(1, Math.round((cached.expiresAt - now) / 60000)),
                })}{' '}
                <button type="button" className="linkish" onClick={() => setUsePinAnyway(true)}>
                  {t('estimates.enterPinAnyway')}
                </button>
              </p>
            ) : (
              <PinInput id="dl-pin" value={pin} onChange={setPin} />
            )}
            <button type="submit" disabled={busy || lines.length === 0 || bad.length > 0}>
              {busy ? t('estimates.saving') : t('deliveries.save')}
            </button>
            <p className="hint">{t('deliveries.goesToQueue')}</p>
          </section>
        </form>
      )}
      <p>
        <Link to="/control/queue">{t('deliveries.openQueue')}</Link>
      </p>
    </main>
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
