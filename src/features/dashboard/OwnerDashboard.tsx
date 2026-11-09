import type { ReactNode } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { CustomerBadge } from '../customers/CustomerBadge';
import { useCustomerLookup, useCustomerNameOf } from '../customers/useCustomerLookup';
import {
  useCurrentEstimates,
  useEstimateGroups,
  useFormulaMinutes,
  useWasherCapacity,
} from '../estimates/estimatesData';
import { round2, summarize } from '../estimates/estimateMath';
import { useAmountText } from '../estimates/useAmountText';
import { DataAge } from '../washroom/DataAge';
import {
  IconCustomer,
  IconIdle,
  IconMachineDown,
  IconReady,
  IconRunning,
  IconWarning,
} from '../washroom/Icons';
import { useLocalizedName } from '../washroom/localizedName';
import { pluralCount } from '../washroom/qtyFormat';
import { errorMessageKey } from '../washroom/rpcError';
import { washerNow } from '../washroom/washerTime';
import type { I18nJson } from '../washroom/washroomData';
import { useQueue, useWashroomBoard } from '../washroom/washroomData';
import { BarList } from './BarList';
import {
  DASHBOARD_REFETCH_MS,
  useFinishedToday,
  useLoadsToday,
  useOffQueueToday,
} from './dashboardData';
import {
  customerWork,
  ownGroups,
  estimateAges,
  finishedToday,
  loadsToday,
  offQueueToday,
  washerCounts,
  washerSegments,
  workByGroup,
  type WasherState,
} from './dashboardLogic';
import './dashboard.css';
import { MoreInfo } from '../../lib/MoreInfo';
import { DESKTOP_FIT_QUERY, useMediaQuery } from '../../lib/useMediaQuery';

// Owner-only Home dashboard (owner 2026-11-09: "I'm a visual guy, I like seeing numbers, in charts,
// coloured correctly"). Real data only: estimates (≈), washer status, washer taps, finished goods.
// No weights, no per-person rows or totals, no invented targets. Every color has words beside it.
// One freshness line for the page sits under the Home title; a card shows its own data age only when
// ITS data may be old or failed (declutter 2026-11-09). On a desktop the grid fits the screen and a
// long card scrolls inside itself (it is then focusable, so the keyboard can scroll it too).
// Managers never render this (HomePage gates it on the owner role).

const REFRESH_S = DASHBOARD_REFETCH_MS / 1000;

interface Props {
  plantId: string;
  washroomId: string | undefined;
  now: number;
}

function Card({
  title,
  link,
  className = '',
  scrolls = false,
  children,
}: {
  title: string;
  link?: { to: string; text: string };
  className?: string;
  /** Desktop fit: the card may scroll inside itself, so it takes keyboard focus. */
  scrolls?: boolean;
  children: ReactNode;
}) {
  const id = `dash-${title.replace(/\W+/g, '-').toLowerCase()}`;
  return (
    <section
      className={`dash-card ${className}`}
      aria-labelledby={id}
      tabIndex={scrolls ? 0 : undefined}
    >
      <div className="dash-card-head">
        <h2 id={id} className="head">
          {title}
        </h2>
        {link && (
          <Link to={link.to} className="dash-link">
            {link.text} <span aria-hidden="true">›</span>
          </Link>
        )}
      </div>
      {children}
    </section>
  );
}

function useAgo() {
  const { t } = useTranslation();
  return (ms: number, now: number) => {
    const min = Math.max(0, Math.floor((now - ms) / 60_000));
    if (min < 60) return t('dash.agoMin', { count: min });
    const h = Math.floor(min / 60);
    return h < 48
      ? t('dash.agoHour', { count: h })
      : t('dash.agoDay', { count: Math.floor(h / 24) });
  };
}

function StateIcon({ state }: { state: WasherState }) {
  if (state === 'running') return <IconRunning />;
  if (state === 'ready') return <IconReady />;
  if (state === 'down') return <IconMachineDown />;
  return <IconIdle />;
}

export function OwnerDashboard({ plantId, washroomId, now }: Props) {
  const { t, i18n } = useTranslation();
  const localized = useLocalizedName();
  const { hours, fmt } = useAmountText();
  const ago = useAgo();
  const fit = useMediaQuery(DESKTOP_FIT_QUERY);
  const lookup = useCustomerLookup();
  const customerName = useCustomerNameOf();
  const groups = useEstimateGroups(plantId);
  const groupCustomer = new Map((groups.data ?? []).map((g) => [g.id, g.customer_id]));
  const customerOf = (groupId: string) =>
    groupCustomer.get(groupId) ?? lookup(groupId)?.customerId ?? null;
  // Estimate totals and the by-group chart count OUR groups only; customers come from the queue.
  const own = ownGroups(groups.data ?? [], customerOf);
  const ownIds = new Set(own.map((g) => g.id));
  const formulas = useFormulaMinutes(plantId);
  const current = useCurrentEstimates(plantId);
  const capacity = useWasherCapacity(plantId);
  const board = useWashroomBoard(washroomId);
  const queue = useQueue(washroomId);
  const pace = useLoadsToday(plantId, true);
  const finished = useFinishedToday(plantId, true);
  const offQueue = useOffQueueToday(plantId, true);

  const cycleOf = (id: string | null) => (id ? (formulas.data?.get(id) ?? null) : null);
  const cap = capacity.data?.capacity ?? 0;
  const washersUp = capacity.data?.washers ?? 0;
  const work = workByGroup(own, current.data ?? new Map(), cycleOf, cap, customerOf);
  // Same totals as the estimates screen: Σ(loads × cycle min) ÷ 60 ÷ working-washer capacity.
  const s = summarize(
    own.flatMap((g) => {
      const last = current.data?.get(g.id);
      if (!last) return [];
      return [
        {
          loads: Number(last.qty) === 0 ? 0 : last.qty_loads,
          cycleMinutes: cycleOf(g.wash_formula_id),
        },
      ];
    }),
    cap,
  );
  const totalHours = s.hours;
  const ages = estimateAges(
    [...(current.data?.values() ?? [])].filter((e) => ownIds.has(e.wash_group_id)),
  );
  const estimatesReady = groups.isSuccess && current.isSuccess && formulas.isSuccess;
  const doneAround =
    totalHours !== null && totalHours > 0
      ? new Intl.DateTimeFormat(i18n.language, { hour: 'numeric', minute: '2-digit' }).format(
          new Date(now + Math.round(totalHours * 60) * 60_000),
        )
      : null;

  const groupName = (w: { name: string; nameI18n: unknown }) =>
    localized(w.name, w.nameI18n as I18nJson);
  const noTime = work.filter((w) => w.loads !== null && w.washerHours === null);
  const noNumber = work.filter((w) => w.loads === null);
  const byHours = cap > 0;
  const chartBars = work
    .filter((w) => (byHours ? w.hours !== null : w.loads !== null))
    .map((w) => ({
      id: w.id,
      name: groupName(w),
      value: byHours ? (w.hours ?? 0) : (w.loads ?? 0),
      valueText: byHours
        ? `≈ ${hours(w.hours ?? 0)}`
        : `≈ ${t('units.load', { count: pluralCount(w.loads ?? 0), n: fmt(w.loads ?? 0) })}`,
      extra: byHours
        ? t('dash.loadsShort', { count: pluralCount(w.loads ?? 0), n: fmt(w.loads ?? 0) })
        : undefined,
      color: w.color,
    }))
    .sort((a, b) => b.value - a.value || a.name.localeCompare(b.name));

  // Washers right now (live status, the same rule as the board and the Home tile).
  const rows = board.data ?? [];
  const counts = washerCounts(
    rows.map((r) => ({
      isDown: !!r.is_down,
      status: washerNow(r.status, r.expected_end_at, r.server_time, board.dataUpdatedAt, now)
        .status,
    })),
  );
  const segments = washerSegments(counts);
  const stateLabel = (st: WasherState) => t(`dash.state.${st}`);

  // Outside customers (AA Linen): every customer that has a wash group, even with nothing waiting.
  // From the open queue only (loads not started), never from estimates.
  const formulaOfGroup = new Map((groups.data ?? []).map((g) => [g.id, g.wash_formula_id]));
  const customers = customerWork(
    queue.data ?? [],
    customerOf,
    (id) => cycleOf(formulaOfGroup.get(id) ?? null),
    cap,
  );
  const customerGroup = new Map<string, string>();
  for (const g of groups.data ?? []) {
    const id = customerOf(g.id);
    if (id && !customerGroup.has(id)) customerGroup.set(id, g.id);
  }
  for (const id of customerGroup.keys())
    if (!customers.some((c) => c.customerId === id))
      customers.push({
        customerId: id,
        queueItems: 0,
        queueLoads: 0,
        queueWithoutCount: 0,
        queueHours: null,
      });

  const today = loadsToday(pace.data ?? []);
  const fg = finishedToday(finished.data ?? []);
  const oq = offQueueToday(offQueue.data ?? []);
  const dayText = today.productionDate
    ? new Intl.DateTimeFormat(i18n.language, {
        weekday: 'short',
        month: 'short',
        day: 'numeric',
        timeZone: 'UTC',
      }).format(new Date(`${today.productionDate}T12:00:00Z`))
    : null;

  return (
    <div
      className={customers.length > 0 ? 'dash' : 'dash no-cust'}
      role="region"
      aria-label={t('dash.region')}
    >
      {/* 1. Hours of work waiting: the most important number. */}
      <Card
        title={t('dash.hoursTitle')}
        className="dash-hero"
        scrolls={fit}
        link={{ to: '/control/estimates', text: t('nav.estimates') }}
      >
        {!estimatesReady ? (
          <p role="status">{t('common.loading')}</p>
        ) : current.data?.size === 0 ? (
          <p className="notice">{t('dash.noEstimates')}</p>
        ) : (
          <>
            <p className="dash-hero-big">
              {totalHours === null ? (
                <span className="dash-hero-none">{t('estimates.noWashTime')}</span>
              ) : (
                <>
                  <span>≈ {hours(totalHours)}</span>{' '}
                  <span className="dash-hero-unit">{t('dash.ofWashing')}</span>
                </>
              )}
            </p>
            <p className="dash-hero-sub">
              {t('dash.loadsWaiting', { count: pluralCount(s.loads), n: fmt(round2(s.loads)) })}
              {' · '}
              {washersUp > 0 ? t('dash.onWashers', { count: washersUp }) : t('estimates.noWashers')}
            </p>
            {doneAround && (
              <p className="dash-done">{t('home.doneAround', { time: doneAround })}</p>
            )}
            {noTime.length > 0 && (
              <p className="hint">
                <IconWarning />{' '}
                {t('dash.noTimeList', {
                  count: noTime.length,
                  names: noTime.map(groupName).join(', '),
                })}
              </p>
            )}
            {noNumber.length > 0 && (
              <p className="hint">
                <IconWarning />{' '}
                {t('dash.noNumberList', {
                  count: noNumber.length,
                  names: noNumber.map(groupName).join(', '),
                })}
              </p>
            )}
            {ages && (
              <p className="dash-age-line">
                {t('dash.estimateAges', {
                  newest: ago(ages.newest, now),
                  oldest: ago(ages.oldest, now),
                })}
              </p>
            )}
            {ages && ages.old > 0 && (
              <p className="dash-warn-line">
                <IconWarning /> {t('dash.oldEstimates', { count: ages.old })}
              </p>
            )}
          </>
        )}
        <DataAge
          quiet
          updatedAt={current.dataUpdatedAt}
          now={now}
          isFetching={current.isFetching}
          isError={current.isError}
          refreshSeconds={REFRESH_S}
        />
      </Card>

      {/* 3. Washers right now. */}
      <Card
        title={t('dash.washersTitle')}
        className="dash-wash"
        scrolls={fit}
        link={{ to: '/control/washers', text: t('nav.washers') }}
      >
        {board.isError && !board.data ? (
          <p className="error">{t(errorMessageKey(board.error))}</p>
        ) : !board.data ? (
          <p role="status">{t('common.loading')}</p>
        ) : counts.total === 0 ? (
          <p className="hint">{t('dash.noWashersSet')}</p>
        ) : (
          <>
            <p className="dash-stat">
              <span className="dash-stat-num">{counts.running}</span>{' '}
              <span>{t('dash.runningOf', { count: counts.total })}</span>
            </p>
            <div
              className="dash-seg"
              role="img"
              aria-label={segments.map((sg) => `${stateLabel(sg.state)}: ${sg.count}`).join(', ')}
            >
              {segments.map((sg) => (
                <span
                  key={sg.state}
                  className={`dash-seg-part seg-${sg.state}${sg.state === 'down' ? ' stripes-danger' : ''}`}
                  style={{ flexGrow: sg.count }}
                  title={`${stateLabel(sg.state)}: ${sg.count}`}
                >
                  {sg.count}
                </span>
              ))}
            </div>
            <ul className="dash-legend">
              {(['running', 'ready', 'idle', 'down'] as const).map((st) => (
                <li key={st} className={counts[st] === 0 ? 'zero' : undefined}>
                  <span className={`dash-key seg-${st}`} aria-hidden="true" />
                  <StateIcon state={st} /> {stateLabel(st)}{' '}
                  <strong className="mono">{counts[st]}</strong>
                </li>
              ))}
            </ul>
          </>
        )}
        <DataAge
          quiet
          updatedAt={board.dataUpdatedAt}
          now={now}
          isFetching={board.isFetching}
          isError={board.isError}
        />
      </Card>

      {/* 2. Hours waiting by wash group. */}
      <Card title={t('dash.byGroupTitle')} className="dash-wide dash-group" scrolls={fit}>
        {!estimatesReady ? (
          <p role="status">{t('common.loading')}</p>
        ) : chartBars.length === 0 ? (
          <p className="hint">{t('dash.byGroupEmpty')}</p>
        ) : (
          <>
            <MoreInfo>
              {byHours
                ? t('dash.byGroupHintHours', { count: washersUp })
                : t('dash.byGroupHintLoads')}
            </MoreInfo>
            <BarList bars={chartBars} label={t('dash.byGroupTitle')} initial={10} />
          </>
        )}
        <DataAge
          quiet
          updatedAt={current.dataUpdatedAt}
          now={now}
          isFetching={current.isFetching}
          isError={current.isError}
          refreshSeconds={REFRESH_S}
        />
      </Card>

      {/* AA Linen (outside customers) waiting, apart from our own goods. */}
      {customers.length > 0 && (
        <div className="dash-cust">
          {customers.map((c) => {
            const gid = customerGroup.get(c.customerId) ?? null;
            const name = customerName(gid) ?? t('customers.generic');
            const nothing = c.queueItems === 0;
            return (
              <Card
                key={c.customerId}
                title={t('dash.customerTitle', { name })}
                className="dash-customer"
                scrolls={fit}
                link={{ to: '/control/queue', text: t('nav.queue') }}
              >
                {nothing ? (
                  <p className="hint">
                    <IconReady /> {t('dash.customerNone')}
                  </p>
                ) : (
                  <>
                    <p className="dash-stat">
                      <IconCustomer /> <span className="dash-stat-num">{fmt(c.queueLoads)}</span>{' '}
                      <span>{t('dash.loadsNotStarted', { count: pluralCount(c.queueLoads) })}</span>
                    </p>
                    <p className="dash-hero-sub">
                      {t('dash.customerItems', { count: c.queueItems })}
                      {c.queueHours !== null &&
                        c.queueLoads > 0 &&
                        ` · ${t('dash.customerQueueHours', { time: hours(c.queueHours) })}`}
                    </p>
                    {c.queueWithoutCount > 0 && (
                      <p className="hint">
                        <IconWarning /> {t('dash.withoutCount', { count: c.queueWithoutCount })}
                      </p>
                    )}
                  </>
                )}
                <DataAge
                  quiet
                  updatedAt={queue.dataUpdatedAt}
                  now={now}
                  isFetching={queue.isFetching}
                  isError={queue.isError}
                  refreshSeconds={REFRESH_S}
                />
              </Card>
            );
          })}
        </div>
      )}

      {/* 4. Loads washed this production day. */}
      <Card title={t('dash.loadsTodayTitle')} className="dash-loads" scrolls={fit}>
        {pace.isError && !pace.data ? (
          <p className="error">{t(errorMessageKey(pace.error))}</p>
        ) : !pace.data ? (
          <p role="status">{t('common.loading')}</p>
        ) : (
          <>
            {dayText && (
              <p className="dash-age-line">{t('dash.productionDay', { date: dayText })}</p>
            )}
            <p className="dash-stat">
              <span className="dash-stat-num">{fmt(today.standard)}</span>{' '}
              <span>{t('dash.standardLoads', { count: pluralCount(today.standard) })}</span>
            </p>
            <p className="dash-hero-sub">
              {t('dash.rewashLoads', { count: today.rewash })} · {t('dash.rewashApart')}
            </p>
            {today.groups.length === 0 ? (
              <p className="hint">{t('dash.noLoadsToday')}</p>
            ) : (
              <BarList
                label={t('dash.loadsTodayTitle')}
                initial={6}
                bars={today.groups.map((g) => ({
                  id: g.id,
                  name: localized(g.name, g.nameI18n as I18nJson),
                  value: g.standard,
                  valueText: t('units.load', {
                    count: pluralCount(g.standard),
                    n: fmt(g.standard),
                  }),
                  extra: g.rewash > 0 ? t('dash.plusRewash', { count: g.rewash }) : undefined,
                  color: g.color,
                  tag: lookup(g.id) ? <CustomerBadge washGroupId={g.id} /> : undefined,
                }))}
              />
            )}
          </>
        )}
        <DataAge
          quiet
          updatedAt={pace.dataUpdatedAt}
          now={now}
          isFetching={pace.isFetching}
          isError={pace.isError}
          refreshSeconds={REFRESH_S}
        />
      </Card>

      {/* Off-queue washer starts today, by reason (owner 2026-11-09). Counts only, no names. */}
      <Card title={t('dash.offQueueTitle')} className="dash-offq" scrolls={fit}>
        {offQueue.isError && !offQueue.data ? (
          <p className="error">{t(errorMessageKey(offQueue.error))}</p>
        ) : !offQueue.data ? (
          <p role="status">{t('common.loading')}</p>
        ) : oq.total === 0 ? (
          <p className="notice">
            <IconReady /> {t('dash.offQueueNone')}
          </p>
        ) : (
          <>
            <p className="dash-stat">
              <span className="dash-stat-num">{oq.total}</span>{' '}
              <span>{t('dash.offQueueStarts', { count: oq.total })}</span>
            </p>
            {oq.lastAt !== null && (
              <p className="dash-age-line">
                {t('dash.offQueueLast', {
                  time: new Intl.DateTimeFormat(i18n.language, {
                    hour: 'numeric',
                    minute: '2-digit',
                  }).format(new Date(oq.lastAt)),
                })}
              </p>
            )}
            <BarList
              label={t('dash.offQueueByReason')}
              initial={4}
              bars={oq.reasons.map((r) => ({
                id: r.reason,
                name: t(`offQueue.reason.${r.reason}`),
                value: r.starts,
                valueText: fmt(r.starts),
                color: null,
              }))}
            />
          </>
        )}
        <DataAge
          quiet
          updatedAt={offQueue.dataUpdatedAt}
          now={now}
          isFetching={offQueue.isFetching}
          isError={offQueue.isError}
          refreshSeconds={REFRESH_S}
        />
      </Card>

      {/* 5. Finished goods this production day (voided entries left out). */}
      <Card title={t('dash.finishedTitle')} className="dash-wide dash-fin" scrolls={fit}>
        {finished.isError && !finished.data ? (
          <p className="error">{t(errorMessageKey(finished.error))}</p>
        ) : !finished.data ? (
          <p role="status">{t('common.loading')}</p>
        ) : fg.entries === 0 ? (
          <p className="notice">{t('dash.noFinished')}</p>
        ) : (
          <>
            <p className="dash-stat">
              <span className="dash-stat-num">{fmt(fg.pieces)}</span>{' '}
              <span>{t('dash.pieces', { count: fg.pieces })}</span>
            </p>
            <p className="dash-hero-sub">
              {t('dash.fromEntries', { count: fg.entries })}
              {fg.voided > 0 && ` · ${t('dash.voided', { count: fg.voided })}`}
            </p>
            {(finished.data?.length ?? 0) >= 500 && <p className="hint">{t('dash.capped')}</p>}
            <BarList
              label={t('dash.finishedTitle')}
              initial={8}
              bars={fg.items.map((it) => ({
                id: it.id,
                name: localized(it.name, it.nameI18n as I18nJson),
                value: it.pieces,
                valueText: t('units.piece', { count: it.pieces, n: fmt(it.pieces) }),
                color: null,
              }))}
            />
          </>
        )}
        <DataAge
          quiet
          updatedAt={finished.dataUpdatedAt}
          now={now}
          isFetching={finished.isFetching}
          isError={finished.isError}
          refreshSeconds={REFRESH_S}
        />
      </Card>
    </div>
  );
}
