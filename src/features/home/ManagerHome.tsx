import type { ReactElement } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useLocalNames } from '../../lib/seededNames';
import { usePlant, useLoadOutPermissions } from '../loadout/loadOutData';
import { useCustomers } from '../deliveries/deliveriesData';
import { useLocalizedName } from '../washroom/localizedName';
import { useReasonLabeler } from '../washroom/downReasons';
import {
  IconCustomer,
  IconEdit,
  IconIdle,
  IconMachineDown,
  IconReady,
  IconRunning,
  IconTruck,
  IconWarning,
} from '../washroom/Icons';
import { minutesLeftRoundedUp, washerNow } from '../washroom/washerTime';
import { useWashroomBoard } from '../washroom/washroomData';

// Manager / lead Home, top part (owner 2026-11-10): what a manager looks at all the time, across the
// whole width of the screen, then a list. First every washer (1 to 6) with what it is doing now, then
// big shortcuts straight into the entry screens. The rest of Home (dirty work, queue, next truck,
// tasks, machines down) follows as full-width rows (HomePage, `home-rows`).

/** Washers 1–6 at a glance. Each washer opens its own screen (a down washer opens Machines). */
export function WasherStrip({ washroomId, now }: { washroomId: string | undefined; now: number }) {
  const { t } = useTranslation();
  const names = useLocalNames();
  const localized = useLocalizedName();
  const labeler = useReasonLabeler();
  const board = useWashroomBoard(washroomId);
  const rows = board.data ?? [];
  const views = rows.map((r) => ({
    row: r,
    view: washerNow(r.status, r.expected_end_at, r.server_time, board.dataUpdatedAt, now),
  }));
  const running = views.filter((v) => !v.row.is_down && v.view.status === 'running').length;

  return (
    <section className="mh-section" aria-labelledby="mh-washers">
      <div className="mh-section-head">
        <h2 id="mh-washers">{t('nav.washers')}</h2>
        {rows.length > 0 && (
          <span className="mh-count mono">
            {t('board.running', { n: running, total: rows.length })}
          </span>
        )}
        <Link to="/control/washers" className="mh-more">
          {t('managerHome.allWashers')} <span aria-hidden="true">›</span>
        </Link>
      </div>
      {!board.data ? (
        <p role="status">{t('common.loading')}</p>
      ) : (
        <ul className="mh-washers">
          {views.map(({ row, view }) => {
            const down = !!row.is_down;
            const state = down ? 'down' : view.status;
            const why =
              down && row.down_reason_code
                ? labeler(row.down_reason_code, row.down_reason_label_i18n)
                : null;
            return (
              <li
                key={row.machine_id}
                className={`mh-washer ${state}${down ? ' stripes-danger' : ''}`}
              >
                <Link
                  to={
                    down
                      ? `/control/machines?machine=${row.machine_id}`
                      : `/station/washer/${row.machine_id}`
                  }
                  className="mh-washer-link"
                >
                  <span className="mh-washer-name head">{names.machine(row.machine_name)}</span>
                  <span className="mh-washer-state">
                    {state === 'down' ? (
                      <>
                        <IconMachineDown /> {t('board.pill.down')}
                      </>
                    ) : state === 'running' ? (
                      <>
                        <IconRunning /> {t('board.pill.running')}
                      </>
                    ) : state === 'ready' ? (
                      <>
                        <IconReady /> {t('board.pill.ready')}
                      </>
                    ) : state === 'idle' ? (
                      <>
                        <IconIdle /> {t('board.pill.idle')}
                      </>
                    ) : (
                      <>
                        <IconWarning /> {t('board.pill.unknown')}
                      </>
                    )}
                  </span>
                  {state === 'running' && view.left !== null && (
                    <span className="mh-washer-time">
                      <span className="mh-washer-big mono" aria-hidden="true">
                        {minutesLeftRoundedUp(view.left)}
                      </span>
                      <span className="mh-washer-unit" aria-hidden="true">
                        {t('board.minLeft')}
                      </span>
                      <span className="visually-hidden">
                        {t('managerHome.minLeft', { count: minutesLeftRoundedUp(view.left) })}
                      </span>
                    </span>
                  )}
                  {state === 'ready' && view.readyMinutes !== null && (
                    <span className="mh-washer-big mono">
                      {t('washroom.waitingMinutes', { count: view.readyMinutes })}
                    </span>
                  )}
                  {why && <span className="mh-washer-sub">{why}</span>}
                  {!down && row.cycle_id && row.wash_group_name && (
                    <span className="mh-washer-sub">
                      {localized(row.wash_group_name, row.wash_group_name_i18n)}
                    </span>
                  )}
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}

/** Big shortcuts straight into the screens a manager types on. */
export function QuickActions({
  userId,
  plantId,
  isManager,
  canFinish = false,
  finishOnly = false,
}: {
  userId: string;
  plantId: string | undefined;
  isManager: boolean;
  /** Owner or manager, and the plant has a finishing area: "Finished goods" (owner 2026-11-10). */
  canFinish?: boolean;
  /** Only the "Finished goods" shortcut (the owner's Home). */
  finishOnly?: boolean;
}) {
  const { t } = useTranslation();
  const localized = useLocalizedName();
  const plant = usePlant(plantId);
  const perms = useLoadOutPermissions(userId, plant.data ?? undefined);
  const customers = useCustomers(isManager ? plantId : undefined);
  const active = (customers.data ?? []).filter((c) => c.active);
  const only = active.length === 1 ? active[0] : undefined;
  const actions = [
    canFinish && {
      to: '/control/finished',
      icon: <IconReady size="1.6em" />,
      label: t('finished.title'),
    },
    isManager && {
      to: '/control/estimates',
      icon: <IconEdit size="1.6em" />,
      label: t('managerHome.enterEstimates'),
    },
    isManager &&
      active.length > 0 && {
        to: '/control/estimates?view=aa&dropoff=1',
        icon: <IconCustomer size="1.6em" />,
        label: only
          ? t('managerHome.dropOffFor', { name: localized(only.name, only.name_i18n) })
          : t('managerHome.dropOff'),
      },
    (perms.data?.canEnter ?? false) && {
      to: '/control/load-out/entry',
      icon: <IconTruck size="1.6em" />,
      label: t('loadOut.entryTitle'),
    },
  ]
    .filter((a): a is { to: string; icon: ReactElement; label: string } => !!a)
    .filter((a) => !finishOnly || a.to === '/control/finished');
  if (actions.length === 0) return null;
  return (
    <nav className="mh-actions" aria-label={t('managerHome.shortcuts')}>
      {actions.map((a) => (
        <Link key={a.to} to={a.to} className="mh-action">
          <span aria-hidden="true">{a.icon}</span>
          <span>{a.label}</span>
        </Link>
      ))}
    </nav>
  );
}
