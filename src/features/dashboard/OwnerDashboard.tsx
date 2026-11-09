import type { ReactNode } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { DirtyWorkSummary } from '../dirtyWork/DirtyWorkSummary';
import { useDirtyWork } from '../dirtyWork/useDirtyWork';
import { useAmountText } from '../estimates/useAmountText';
import { DataAge } from '../washroom/DataAge';
import { IconIdle, IconMachineDown, IconReady, IconRunning, IconWarning } from '../washroom/Icons';
import { useLocalizedName } from '../washroom/localizedName';
import { errorMessageKey } from '../washroom/rpcError';
import { washerNow } from '../washroom/washerTime';
import type { I18nJson } from '../washroom/washroomData';
import { useWashroomBoard } from '../washroom/washroomData';
import { CustomerBadge } from '../customers/CustomerBadge';
import { useCustomerLookup } from '../customers/useCustomerLookup';
import { BarList } from './BarList';
import { DASHBOARD_REFETCH_MS, useLoadsToday, useOffQueueToday } from './dashboardData';
import {
  loadsToday,
  offQueueToday,
  washerCounts,
  washerSegments,
  type WasherState,
} from './dashboardLogic';
import './dashboard.css';
import { DESKTOP_FIT_QUERY, useMediaQuery } from '../../lib/useMediaQuery';

// Owner-only Home dashboard (owner 2026-11-09; app review items 1 and 7). Three cards:
// - "Dirty work out there" (one card for what is waiting, by category, AA Linen apart; the same
//   selector as the manager tile, Estimates and the Queue header, so the numbers never disagree);
// - Washers right now, with one line for off-queue starts when there were any today;
// - Loads washed today, as loads STARTED (standard loads stay in the reports).
// "Finished goods today" is hidden until the finishing entry screen exists (owner OK 2026-11-09).
// Real data only: no weights, no per-person rows or totals, no invented targets. On a desktop the
// grid fits the screen; a long card scrolls inside itself (then it is focusable for the keyboard).
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

function StateIcon({ state }: { state: WasherState }) {
  if (state === 'running') return <IconRunning />;
  if (state === 'ready') return <IconReady />;
  if (state === 'down') return <IconMachineDown />;
  return <IconIdle />;
}

export function OwnerDashboard({ plantId, washroomId, now }: Props) {
  const { t, i18n } = useTranslation();
  const localized = useLocalizedName();
  const { fmt } = useAmountText();
  const fit = useMediaQuery(DESKTOP_FIT_QUERY);
  const lookup = useCustomerLookup();
  const dirty = useDirtyWork(plantId);
  const board = useWashroomBoard(washroomId);
  const pace = useLoadsToday(plantId, true);
  const offQueue = useOffQueueToday(plantId, true);

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

  const today = loadsToday(pace.data ?? []);
  const started = (pace.data ?? []).reduce((n, r) => n + Math.max(0, Number(r.loads_run) || 0), 0);
  const startedOf = new Map(
    (pace.data ?? []).map((r) => [r.wash_group_id, Math.max(0, Number(r.loads_run) || 0)]),
  );
  const oq = offQueueToday(offQueue.data ?? []);
  const oqReasons = oq.reasons.filter((r) => r.starts > 0);
  const oqText =
    oqReasons.length === 1
      ? t(`offQueue.reason.${oqReasons[0]?.reason ?? 'other'}`)
      : oqReasons.map((r) => `${t(`offQueue.reason.${r.reason}`)} ${r.starts}`).join(' · ');
  const dayText = today.productionDate
    ? new Intl.DateTimeFormat(i18n.language, {
        weekday: 'short',
        month: 'short',
        day: 'numeric',
        timeZone: 'UTC',
      }).format(new Date(`${today.productionDate}T12:00:00Z`))
    : null;

  return (
    <div className="dash" role="region" aria-label={t('dash.region')}>
      {/* 1. Dirty work out there: what is waiting, by category (review §3). */}
      <section
        className="dash-card dash-hero"
        aria-labelledby="dash-dirty"
        tabIndex={fit ? 0 : undefined}
      >
        <DirtyWorkSummary
          dirty={dirty}
          now={now}
          title={t('dirty.title')}
          headingId="dash-dirty"
          headerLink={{ to: '/control/estimates', text: t('nav.estimates') }}
        />
      </section>

      {/* 2. Washers right now (+ off-queue starts today, one line, only when there were any). */}
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
        {offQueue.isError && !offQueue.data ? (
          <p className="hint">
            <IconWarning /> {t('dash.offQueueTitle')}: {t(errorMessageKey(offQueue.error))}
          </p>
        ) : (
          oq.total > 0 && (
            <p className="dash-offq-line">
              <IconWarning /> {t('dash.offQueueLine', { count: oq.total, reasons: oqText })}
            </p>
          )
        )}
        <DataAge
          quiet
          updatedAt={board.dataUpdatedAt}
          now={now}
          isFetching={board.isFetching}
          isError={board.isError}
        />
        {offQueue.isError && offQueue.data && (
          <DataAge
            quiet
            updatedAt={offQueue.dataUpdatedAt}
            now={now}
            isFetching={offQueue.isFetching}
            isError={offQueue.isError}
            refreshSeconds={REFRESH_S}
          />
        )}
      </Card>

      {/* 3. Loads washed this production day: loads STARTED (a count), rewash included. */}
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
              <span className="dash-stat-num">{fmt(started)}</span>{' '}
              <span>{t('dash.loadsStarted', { count: started })}</span>
            </p>
            {today.rewash > 0 && (
              <p className="dash-hero-sub">{t('dash.rewashIncluded', { count: today.rewash })}</p>
            )}
            {today.groups.length === 0 ? (
              <p className="hint">{t('dash.noLoadsToday')}</p>
            ) : (
              <BarList
                label={t('dash.loadsTodayTitle')}
                initial={6}
                bars={today.groups
                  .map((g) => {
                    const n = startedOf.get(g.id) ?? 0;
                    return {
                      id: g.id,
                      name: localized(g.name, g.nameI18n as I18nJson),
                      value: n,
                      valueText: t('units.load', { count: n, n: fmt(n) }),
                      extra:
                        g.rewash > 0 ? t('dash.rewashIncluded', { count: g.rewash }) : undefined,
                      // One neutral series (review §3: group colours carry no meaning here).
                      color: null,
                      tag: lookup(g.id) ? <CustomerBadge washGroupId={g.id} /> : undefined,
                    };
                  })
                  .sort((a, b) => b.value - a.value || a.name.localeCompare(b.name))}
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
    </div>
  );
}
