import { useEffect, useRef, useState, type FormEvent } from 'react';
import { useSearchParams } from 'react-router';
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
import { useAmountText } from './useAmountText';
import { parseAmount, toLoads, type EstimateUnit } from './estimateMath';
import { wholeLoads, type DirtyEstimateInput } from '../dirtyWork/dirtyWork';
import { DirtyWorkSummary } from '../dirtyWork/DirtyWorkSummary';
import { useDirtyWork } from '../dirtyWork/useDirtyWork';
import type { OutboxBatch } from './estimateOutbox';
import {
  useCurrentEstimates,
  useEstimateGroups,
  useFormulaMinutes,
  useGroupCategories,
  useWasherCapacity,
} from './estimatesData';
import { chipCounts, chipsFor, effectiveChip, inChip } from './categories';
import { useChip } from './useChip';
import { CategoryChips } from './CategoryChips';
import { useCustomers } from '../deliveries/deliveriesData';
import { AaDropOffView } from '../deliveries/AaDropOffView';
import { useEstimateOutbox } from './useEstimateOutbox';
import '../../lib/forms.css';
import '../washroom/washroom.css';
import './estimates.css';
import { MoreInfo } from '../../lib/MoreInfo';

// Soil estimates (PRD B1; owner 2026-11-04): the shift manager estimates the dirty work waiting per
// wash group, reviews, and saves the whole batch at once. Owner and managers only. No names on any
// estimate (2026-11-07: no entry PIN either; the signed-in account is the attribution). Every
// insert carries a client_id; the batch goes through the device outbox so nothing is lost offline.
// Owner 2026-11-09: category chips instead of one long list, and a second view, "AA Linen": what AA has
// waiting now, "+ AA Linen drop-off" and today's drop-offs (AaDropOffView; review item 5).

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
  return (
    <EstimatesScreen userId={session.user.id} plantId={plantId} isOwner={myRoles.has('owner')} />
  );
}

function EstimatesScreen({
  userId,
  plantId,
  isOwner,
}: {
  userId: string;
  plantId: string;
  isOwner: boolean;
}) {
  const { t } = useTranslation();
  const now = useNow(15_000);
  const online = useOnline();
  const localized = useLocalizedName();
  const { amount, fmt } = useAmountText();

  const groups = useEstimateGroups(plantId);
  // "Our work" = our own groups only. Outside customers' groups (AA Linen) live in the customer view:
  // their goods arrive by delivery into the queue, so estimating them too would double count.
  const ownList = (groups.data ?? []).filter((g) => g.customer_id === null);
  const formulas = useFormulaMinutes(plantId);
  const current = useCurrentEstimates(plantId);
  useLiveRefetch(current.refetch, !!plantId);
  const capacity = useWasherCapacity(plantId);
  const outbox = useEstimateOutbox(userId);
  const [params, setParams] = useSearchParams();

  const [drafts, setDrafts] = useState<Record<string, Draft>>({});
  const [openId, setOpenId] = useState<string | null>(null);
  const [reviewing, setReviewing] = useState(false);
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
  const changes = ownList.flatMap((g) => {
    const d = drafts[g.id];
    if (!d || d.text.trim() === '') return [];
    const qty = parseAmount(d.text);
    return [{ group: g, unit: d.unit, qty, loads: qty === null ? null : toLoads(qty, d.unit, g) }];
  });
  const invalid = changes.filter((c) => c.qty === null);

  // Top summary (the shared "Dirty work" card): unsaved changes where made, else the last save.
  const merged = new Map<string, DirtyEstimateInput>(current.data ?? []);
  for (const c of changes)
    if (c.qty !== null) merged.set(c.group.id, { qty: c.qty, unit: c.unit, qty_loads: c.loads });
  const dirty = useDirtyWork(plantId, { estimates: merged });
  const totalGroups = ownList.length;
  const estimatedGroups = ownList.filter((g) => current.data?.has(g.id)).length;
  const needsCount = totalGroups - estimatedGroups;
  // "?needs=1" (from Home's "Not estimated: N groups ›") opens the Needs estimate filter.
  const [needsOnly, setNeedsOnly] = useState(() => params.get('needs') === '1');
  // Category chips (owner 2026-11-09): counts = groups with work waiting (unsaved change or last save).
  const categories = useGroupCategories(plantId);
  const categoryOf = categories.data ?? new Map();
  const [chipChoice, setChip] = useChip(userId);
  const groupIds = ownList.map((g) => g.id);
  const chips = chipsFor(groupIds, categoryOf);
  const chip = effectiveChip(chipChoice, chips);
  const hasWork = (id: string) => {
    const c = changes.find((x) => x.group.id === id);
    if (c) return (c.qty ?? 0) > 0;
    return Number(current.data?.get(id)?.qty ?? 0) > 0;
  };
  const counts = chipCounts(groupIds, categoryOf, hasWork);
  // "Needs estimate" keeps a row until it is saved, so editing it doesn't make it vanish.
  const shownGroups = ownList.filter(
    (g) =>
      g.id === openId ||
      (inChip(g.id, chip, categoryOf) && (!needsOnly || !current.data?.has(g.id))),
  );

  // "Our work" | customer (AA Linen) view, in the URL so Back and a reload keep it.
  const customers = useCustomers(plantId);
  const activeCustomers = (customers.data ?? []).filter((c) => c.active);
  const view = params.get('view') === 'aa' && activeCustomers.length > 0 ? 'aa' : 'ours';
  const setView = (v: 'ours' | 'aa') =>
    setParams(v === 'aa' ? { view: 'aa' } : {}, { replace: true });
  const onlyCustomer = activeCustomers.length === 1 ? activeCustomers[0] : undefined;
  // The tab is the customer (what AA has waiting + its drop-offs), not only the drop-off form.
  const aaLabel = onlyCustomer
    ? localized(onlyCustomer.name, onlyCustomer.name_i18n)
    : t('estimates.customersTab');

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
    const valid = changes.filter((c) => c.qty !== null);
    if (valid.length === 0) return;
    setBusy(true);
    setMessage(null);
    try {
      const enteredAt = new Date(Date.now() + (capacity.data?.serverOffsetMs ?? 0)).toISOString();
      const batch: OutboxBatch = {
        batchId: crypto.randomUUID(),
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
      const r = await outbox.submit(batch);
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

  const pendingCount = outbox.pending.reduce((n, b) => n + b.entries.length, 0);

  const messages = (
    <>
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
    </>
  );

  return (
    <main className="form-page estimates-page">
      <div className="est-title">
        <h1>{t('estimates.title')}</h1>
        {activeCustomers.length > 0 && (
          <div className="est-views" role="group" aria-label={t('estimates.viewLabel')}>
            <button type="button" aria-pressed={view === 'ours'} onClick={() => setView('ours')}>
              {t('estimates.ourWork')}
            </button>
            <button type="button" aria-pressed={view === 'aa'} onClick={() => setView('aa')}>
              {aaLabel}
            </button>
          </div>
        )}
      </div>

      {view === 'aa' ? (
        <>
          {/* Unsaved estimates stay put while the customer view is open. */}
          {messages}
          <AaDropOffView
            userId={userId}
            plantId={plantId}
            isOwner={isOwner}
            dirty={dirty}
            customer={onlyCustomer}
            startOpen={params.get('dropoff') === '1'}
          />
        </>
      ) : (
        <div className="est-layout">
          <div className="est-side">
            <MoreInfo>{t('estimates.intro')}</MoreInfo>
            <section className="est-hero" aria-labelledby="sum-title">
              <DirtyWorkSummary
                dirty={dirty}
                now={now}
                title={t('dirty.title')}
                headingId="sum-title"
                showNotEstimated={false}
                extra={
                  <>
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
                        <p>
                          {t('estimates.groupsEstimated', {
                            done: estimatedGroups,
                            total: totalGroups,
                          })}
                        </p>
                        {(needsCount > 0 || needsOnly) && (
                          <button
                            type="button"
                            className="secondary est-needs"
                            aria-pressed={needsOnly}
                            onClick={() => setNeedsOnly((v) => !v)}
                          >
                            {t('estimates.filterNeeds', { count: needsCount })}
                          </button>
                        )}
                      </div>
                    )}
                    {changes.length > 0 && (
                      <p className="hint">
                        {t('estimates.includesUnsaved', { count: changes.length })}
                      </p>
                    )}
                  </>
                }
              />
            </section>
            {messages}
          </div>

          <div className="est-main">
            {groups.isPending && <p role="status">{t('common.loading')}</p>}
            {groups.isError && <p className="error">{t(errorMessageKey(groups.error))}</p>}
            <CategoryChips chips={chips} value={chip} counts={counts} onChange={setChip} />
            {needsOnly && needsCount === 0 && groups.isSuccess && (
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
                  now={now}
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
                                  count: pluralize(wholeLoads(c.loads)),
                                  n: fmt(wholeLoads(c.loads)),
                                })
                              : t('estimates.noNumber', { amount: amount(c.qty, c.unit) })}
                    </li>
                  ))}
                </ul>
                {invalid.length > 0 && (
                  <p className="error">{t('estimates.fixFirst', { count: invalid.length })}</p>
                )}
                <form onSubmit={onSave} noValidate autoComplete="off">
                  <button
                    type="submit"
                    disabled={busy || invalid.length > 0 || changes.length === 0}
                  >
                    {busy
                      ? t('estimates.saving')
                      : t('estimates.saveAll', { count: changes.length })}
                  </button>
                  <button type="button" className="secondary" onClick={() => setReviewing(false)}>
                    {t('estimates.keepEditing')}
                  </button>
                </form>
              </section>
            )}
          </div>
        </div>
      )}

      {!reviewing && changes.length > 0 && (
        <div className="save-bar">
          <button
            type="button"
            onClick={() => {
              setView('ours');
              setReviewing(true);
            }}
          >
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
