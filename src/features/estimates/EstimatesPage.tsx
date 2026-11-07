import { useEffect, useRef, useState, type FormEvent } from 'react';
import { useTranslation } from 'react-i18next';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { useNow, useOnline } from '../../lib/useNow';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { IconOffline, IconReady, IconWarning } from '../washroom/Icons';
import { useLocalizedName } from '../washroom/localizedName';
import { errorMessageKey } from '../washroom/rpcError';
import { useAreas } from '../washroom/washroomData';
import { useMyRoles } from '../washroom/useMyRoles';
import { EstimateRow, type Draft } from './EstimateRow';
import { PinInput, RePin } from './PinInput';
import { useAmountText } from './useAmountText';
import { parseAmount, summarize, toLoads, type EstimateUnit } from './estimateMath';
import type { OutboxBatch } from './estimateOutbox';
import {
  useCurrentEstimates,
  useEntryStaff,
  useEstimateGroups,
  useFormulaMinutes,
  usePinReuseMinutes,
  useWasherCapacity,
} from './estimatesData';
import { readLastStaff, startSessionDetailed, useEstimateOutbox } from './useEstimateOutbox';
import '../../lib/forms.css';
import '../washroom/washroom.css';
import './estimates.css';

// Soil estimates (PRD B1; owner 2026-11-04): the shift manager estimates the dirty work waiting per
// wash group, reviews, and saves once with ONE name + PIN for the whole batch. Owner and managers
// only. No names on any estimate. Every insert carries a client_id; the batch goes through the
// device outbox so nothing is lost offline.

/**
 * Role gate (security review: the outbox hook and its flusher only run for owners and managers).
 * Everything else, including useEstimateOutbox, lives in EstimatesScreen below.
 */
export function EstimatesPage() {
  const { t } = useTranslation();
  const session = useRequiredSession();
  const areas = useAreas();
  const plantId = areas.data?.[0]?.plant_id;
  const roles = useMyRoles(session.user.id);
  const myRoles = roles.rolesFor(plantId);
  const allowed = myRoles.has('owner') || myRoles.has('manager');

  if (!roles.isSuccess || !areas.isSuccess || !plantId) {
    return (
      <main className="form-page">
        <p role="status">{t('common.loading')}</p>
      </main>
    );
  }
  if (!allowed) {
    return (
      <main className="form-page">
        <h1>{t('estimates.title')}</h1>
        <p className="notice">{t('estimates.notAllowed')}</p>
      </main>
    );
  }
  return <EstimatesScreen userId={session.user.id} plantId={plantId} />;
}

function EstimatesScreen({ userId, plantId }: { userId: string; plantId: string }) {
  const { t, i18n } = useTranslation();
  const now = useNow(15_000);
  const online = useOnline();
  const localized = useLocalizedName();
  const { amount, hours, fmt } = useAmountText();

  const groups = useEstimateGroups(plantId);
  const formulas = useFormulaMinutes(plantId);
  const current = useCurrentEstimates(plantId);
  useLiveRefetch(current.refetch, !!plantId);
  const staff = useEntryStaff(plantId);
  const reuse = usePinReuseMinutes(plantId);
  const capacity = useWasherCapacity(plantId);
  const outbox = useEstimateOutbox(userId, plantId, reuse.data ?? 0);

  const [drafts, setDrafts] = useState<Record<string, Draft>>({});
  const [openId, setOpenId] = useState<string | null>(null);
  const [reviewing, setReviewing] = useState(false);
  const [staffId, setStaffId] = useState(() => readLastStaff(userId));
  const [pin, setPin] = useState('');
  const [usePinAnyway, setUsePinAnyway] = useState(false);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ kind: 'ok' | 'warn' | 'bad'; text: string } | null>(
    null,
  );
  const reviewRef = useRef<HTMLHeadingElement>(null);

  useEffect(() => {
    if (reviewing) reviewRef.current?.focus();
  }, [reviewing]);

  const cycleFor = (formulaId: string | null) =>
    formulaId ? (formulas.data?.get(formulaId) ?? null) : null;

  // Valid changes, in card order.
  const changes = (groups.data ?? []).flatMap((g) => {
    const d = drafts[g.id];
    if (!d || d.text.trim() === '') return [];
    const qty = parseAmount(d.text);
    return [{ group: g, unit: d.unit, qty, loads: qty === null ? null : toLoads(qty, d.unit, g) }];
  });
  const invalid = changes.filter((c) => c.qty === null);

  // Top summary: unsaved changes where made, else the last saved estimate.
  const summary = summarize(
    (groups.data ?? []).flatMap((g) => {
      const c = changes.find((x) => x.group.id === g.id && x.qty !== null);
      const cycleMinutes = cycleFor(g.wash_formula_id);
      if (c) return [{ loads: c.loads, cycleMinutes }];
      const last = current.data?.get(g.id);
      if (!last) return [];
      return [{ loads: Number(last.qty) === 0 ? 0 : last.qty_loads, cycleMinutes }];
    }),
    capacity.data?.capacity ?? 0,
  );
  const totalGroups = groups.data?.length ?? 0;
  const estimatedGroups = (groups.data ?? []).filter((g) => current.data?.has(g.id)).length;
  const needsCount = totalGroups - estimatedGroups;
  const [filter, setFilter] = useState<'all' | 'needs'>('all');
  // "Needs estimate" keeps a row until it is saved, so editing it doesn't make it vanish.
  const shownGroups = (groups.data ?? []).filter(
    (g) => filter === 'all' || !current.data?.has(g.id) || g.id === openId,
  );
  const doneAround =
    summary.hours !== null && summary.loads > 0
      ? new Intl.DateTimeFormat(i18n.language, { hour: 'numeric', minute: '2-digit' }).format(
          new Date(now + Math.round(summary.hours * 60) * 60_000),
        )
      : null;

  const cached = outbox.cachedSession(staffId || null, now);
  const needPin = !cached || usePinAnyway;

  function setDraft(groupId: string, d: Draft | null) {
    setMessage(null);
    setDrafts((prev) =>
      d
        ? { ...prev, [groupId]: d }
        : Object.fromEntries(Object.entries(prev).filter(([k]) => k !== groupId)),
    );
  }

  async function onSave(e: FormEvent) {
    e.preventDefault();
    if (!staffId) return setMessage({ kind: 'bad', text: t('estimates.errors.who') });
    if (needPin && !/^\d{4}$/.test(pin)) {
      return setMessage({ kind: 'bad', text: t('estimates.errors.pin') });
    }
    const valid = changes.filter((c) => c.qty !== null);
    if (valid.length === 0) return;
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
          outbox.rememberNewSession(staffId, {
            sessionId: s.sessionId,
            expiresAt: s.expiresAt ?? null,
          });
        }
        // s.kind === 'retry': offline. Store the batch with the PIN; it opens a session later.
      }
      const enteredAt = new Date(Date.now() + (capacity.data?.serverOffsetMs ?? 0)).toISOString();
      const batch: OutboxBatch = {
        batchId: crypto.randomUUID(),
        staffId,
        pin: needPin ? pin : '',
        sessionId,
        entries: valid.map((c) => ({
          clientId: crypto.randomUUID(),
          enteredAt: enteredAt,
          washGroupId: c.group.id,
          qty: c.qty as number,
          unit: c.unit as EstimateUnit,
        })),
        createdAt: new Date().toISOString(),
        lastError: null,
      };
      const r = await outbox.submit(batch, staffId);
      setPin('');
      setUsePinAnyway(false);
      setDrafts({});
      setReviewing(false);
      setMessage(
        r.saved === batch.entries.length
          ? { kind: 'ok', text: t('estimates.saved', { count: r.saved }) }
          : r.stored
            ? {
                kind: 'warn',
                text: t('estimates.savedOnPhone', { count: batch.entries.length - r.saved }),
              }
            : { kind: 'bad', text: t('estimates.notStored') },
      );
    } finally {
      setBusy(false);
    }
  }

  const staffName = staff.data?.find((s) => s.id === staffId)?.display_name;
  const pendingCount = outbox.pending.reduce((n, b) => n + b.entries.length, 0);

  return (
    <main className="form-page estimates-page">
      <h1>{t('estimates.title')}</h1>
      <p className="hint">{t('estimates.intro')}</p>

      <section className="est-hero" aria-labelledby="sum-title">
        <h2 id="sum-title" className="est-hero-label">
          {t('estimates.summaryTitle')}
        </h2>
        <p className="est-hero-big">
          <span className="mono">≈ {fmt(summary.loads)}</span>{' '}
          <span className="est-hero-unit">
            {t('estimates.loadsWord', { count: pluralize(summary.loads) })}
          </span>
        </p>
        {doneAround && (
          <p className="est-hero-done">{t('home.doneAround', { time: doneAround })}</p>
        )}
        <p className="hint">
          {summary.hours === null
            ? capacity.data && capacity.data.washers === 0
              ? t('estimates.noWashers')
              : t('estimates.noWashTime')
            : t('estimates.totalHours', {
                time: hours(summary.hours),
                count: capacity.data?.washers ?? 0,
              })}
        </p>
        {totalGroups > 0 && (
          <div className="est-progress">
            <div
              className="est-progress-bar"
              role="progressbar"
              aria-valuemin={0}
              aria-valuemax={totalGroups}
              aria-valuenow={estimatedGroups}
              aria-label={t('estimates.groupsEstimated', {
                done: estimatedGroups,
                total: totalGroups,
              })}
            >
              <span style={{ width: `${(estimatedGroups / totalGroups) * 100}%` }} />
            </div>
            <p>{t('estimates.groupsEstimated', { done: estimatedGroups, total: totalGroups })}</p>
          </div>
        )}
        {summary.unknown > 0 && (
          <p className="hint">
            <IconWarning /> {t('estimates.unknownGroups', { count: summary.unknown })}
          </p>
        )}
        {summary.noTime > 0 && (
          <p className="hint">
            <IconWarning /> {t('estimates.noTimeGroups', { count: summary.noTime })}
          </p>
        )}
        {changes.length > 0 && (
          <p className="hint">{t('estimates.includesUnsaved', { count: changes.length })}</p>
        )}
      </section>

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
        {pendingCount > 0 && !message && (
          <p className="notice notice-warn">
            <IconOffline /> {t('estimates.waitingToSend', { count: pendingCount })}
          </p>
        )}
      </div>
      {!online && (
        <p className="notice notice-warn">
          <IconOffline /> {t('estimates.offline')}
        </p>
      )}
      {outbox.needsPin && <RePin staffId={outbox.needsPin.staffId} onPin={outbox.retryWithPin} />}
      {outbox.rejected.map((r) => {
        const g = groups.data?.find((x) => x.id === r.washGroupId);
        return (
          <div key={r.clientId} className="notice notice-bad" role="alert">
            <p>
              <IconWarning />{' '}
              {t('estimates.rejected', {
                group: g ? localized(g.name, g.name_i18n) : '?',
                amount: amount(r.qty, r.unit),
              })}{' '}
              {r.errorCode === 'OUT_OF_RANGE_TIMESTAMP'
                ? t('estimates.errors.tooOld')
                : t(errorMessageKey({ message: r.errorCode }))}
            </p>
            <button type="button" className="secondary" onClick={() => outbox.dismiss(r.clientId)}>
              {t('station.dismiss')}
            </button>
          </div>
        );
      })}

      {groups.isPending && <p role="status">{t('common.loading')}</p>}
      {groups.isError && <p className="error">{t(errorMessageKey(groups.error))}</p>}

      <div className="est-filter" role="group" aria-label={t('estimates.filterLabel')}>
        <button type="button" aria-pressed={filter === 'all'} onClick={() => setFilter('all')}>
          {t('estimates.filterAll', { count: totalGroups })}
        </button>
        <button type="button" aria-pressed={filter === 'needs'} onClick={() => setFilter('needs')}>
          {t('estimates.filterNeeds', { count: needsCount })}
        </button>
      </div>
      {filter === 'needs' && needsCount === 0 && groups.isSuccess && (
        <p className="hint">
          <IconReady /> {t('estimates.allEstimated')}
        </p>
      )}
      <ul className="estimate-list compact">
        {shownGroups.map((g) => (
          <EstimateRow
            key={g.id}
            group={g}
            cycleMinutes={cycleFor(g.wash_formula_id)}
            last={current.data?.get(g.id)}
            draft={drafts[g.id] ?? null}
            open={openId === g.id}
            onToggle={() => setOpenId((id) => (id === g.id ? null : g.id))}
            onDraft={(d) => setDraft(g.id, d)}
          />
        ))}
      </ul>

      {reviewing && (
        <section className="card review" aria-labelledby="review-title">
          <h2 id="review-title" ref={reviewRef} tabIndex={-1}>
            {t('estimates.reviewTitle', { count: changes.length })}
          </h2>
          <ul>
            {changes.map((c) => (
              <li key={c.group.id}>
                <strong>{localized(c.group.name, c.group.name_i18n)}:</strong>{' '}
                {c.qty === null
                  ? t('estimates.badAmount')
                  : c.qty === 0
                    ? t('estimates.nothingWaiting')
                    : c.unit === 'load'
                      ? amount(c.qty, 'load')
                      : c.loads !== null
                        ? t('estimates.approxLoads', {
                            amount: amount(c.qty, c.unit),
                            count: pluralize(c.loads),
                            n: fmt(c.loads),
                          })
                        : t('estimates.noNumber', { amount: amount(c.qty, c.unit) })}
              </li>
            ))}
          </ul>
          {invalid.length > 0 && (
            <p className="error">{t('estimates.fixFirst', { count: invalid.length })}</p>
          )}
          <form onSubmit={onSave} noValidate autoComplete="off">
            <div className="field">
              <label htmlFor="est-who">{t('estimates.whoLabel')}</label>
              <select id="est-who" value={staffId} onChange={(e) => setStaffId(e.target.value)}>
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
              <PinInput value={pin} onChange={setPin} />
            )}
            <button type="submit" disabled={busy || invalid.length > 0 || changes.length === 0}>
              {busy ? t('estimates.saving') : t('estimates.saveAll', { count: changes.length })}
            </button>
            <button type="button" className="secondary" onClick={() => setReviewing(false)}>
              {t('estimates.keepEditing')}
            </button>
          </form>
        </section>
      )}

      {!reviewing && changes.length > 0 && (
        <div className="save-bar">
          <button type="button" onClick={() => setReviewing(true)}>
            {t('estimates.review', { count: changes.length })}
          </button>
        </div>
      )}
    </main>
  );
}

function pluralize(n: number): number {
  return n <= 1 && n > 0 ? 1 : n;
}
