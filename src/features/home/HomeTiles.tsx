import type { ReactNode } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useLocalNames } from '../../lib/seededNames';
import { useCustomerNameOf } from '../customers/useCustomerLookup';
import { roundedMinutes } from '../dirtyWork/dirtyWork';
import { useDirtyText } from '../dirtyWork/useDirtyText';
import { useDirtyWork } from '../dirtyWork/useDirtyWork';
import { useLocalizedName } from '../washroom/localizedName';
import { errorMessageKey } from '../washroom/rpcError';
import { minutesUntil, nextTruck, localRouteName } from '../loadout/loadOutLogic';
import { useLoadOutBoard, usePlant } from '../loadout/loadOutData';
import { useTasks } from '../tasks/tasksData';
import { useReasonLabeler } from '../washroom/downReasons';
import {
  IconBins,
  IconMachineDown,
  IconQueue,
  IconReady,
  IconRunning,
  IconRush,
  IconTasks,
  IconTruck,
  IconWarning,
  IconWasher,
} from '../washroom/Icons';
import { ageSeconds, estimateServerNow, freshness, washerNow } from '../washroom/washerTime';
import { useMachineStatus, useQueue, useWashroomBoard } from '../washroom/washroomData';
import type { TileId } from './homePrefs';

// Home dashboard tiles (owner 2026-11-06, round 2). Each tile reads the same data as its screen and
// taps through to that screen. One freshness line for the whole page sits under the Home title
// (declutter 2026-11-09); a tile shows its own age only when ITS data may be old or failed to load. Status is never color alone: every
// signal has an icon and words. Green only for "running" / OK.

export type TileTone = 'neutral' | 'ok' | 'warn' | 'danger' | 'info';

interface Ctx {
  userId: string;
  plantId: string | undefined;
  washroomId: string | undefined;
  isOwner: boolean;
  isManager: boolean;
  now: number;
}

/** A tile's data age, shown only when it may be old or the refresh failed (icon + words). */
function TileAge({
  updatedAt,
  now,
  isFetching,
  isError,
}: {
  updatedAt: number;
  now: number;
  isFetching?: boolean;
  isError?: boolean;
}) {
  const { t } = useTranslation();
  if (!updatedAt) return null;
  const age = ageSeconds(updatedAt, now);
  const band = freshness(age);
  if (band === 'fresh' && !isError) return null;
  return (
    <span className={`home-age data-age-${band}`}>
      {band !== 'fresh' && <IconWarning />}
      {age < 60
        ? t('home.ageSec', { count: age })
        : t('home.ageMin', { count: Math.floor(age / 60) })}
      {band !== 'fresh' && ` · ${t('washroom.mayBeOld')}`}
      {isError && ` · ${t('washroom.refreshFailed')}`}
      {isFetching && <span className="visually-hidden">{t('washroom.refreshing')}</span>}
    </span>
  );
}

function Tile({
  to,
  icon,
  title,
  tone = 'neutral',
  wide = false,
  updatedAt,
  isFetching,
  isError,
  now,
  children,
}: {
  to: string;
  icon: ReactNode;
  title: string;
  tone?: TileTone;
  wide?: boolean;
  updatedAt: number;
  isFetching?: boolean;
  isError?: boolean;
  now: number;
  children: ReactNode;
}) {
  const classes = ['home-tile', `tone-${tone}`];
  if (wide) classes.push('wide');
  if (tone === 'danger') classes.push('stripes-danger');
  return (
    <li className={classes.join(' ')}>
      <Link to={to} className="home-tile-link">
        <span className="home-tile-head">
          <span className="home-tile-icon" aria-hidden="true">
            {icon}
          </span>
          <span className="home-tile-title head">{title}</span>
          <span className="home-tile-chevron" aria-hidden="true">
            ›
          </span>
        </span>
        <span className="home-tile-body">{children}</span>
        <TileAge updatedAt={updatedAt} now={now} isFetching={isFetching} isError={isError} />
      </Link>
    </li>
  );
}

function Loading() {
  const { t } = useTranslation();
  return <span className="home-sub">{t('common.loading')}</span>;
}

function WashersTile({ c }: { c: Ctx }) {
  const { t } = useTranslation();
  const board = useWashroomBoard(c.washroomId);
  const rows = board.data ?? [];
  const running = rows.filter(
    (r) =>
      !r.is_down &&
      washerNow(r.status, r.expected_end_at, r.server_time, board.dataUpdatedAt, c.now).status ===
        'running',
  ).length;
  const ready = rows.filter(
    (r) =>
      !r.is_down &&
      washerNow(r.status, r.expected_end_at, r.server_time, board.dataUpdatedAt, c.now).status ===
        'ready',
  ).length;
  const down = rows.filter((r) => r.is_down).length;
  return (
    <Tile
      to="/control/washers"
      icon={<IconWasher size="1.5em" />}
      title={t('nav.washers')}
      tone={running > 0 ? 'ok' : 'neutral'}
      updatedAt={board.dataUpdatedAt}
      isFetching={board.isFetching}
      isError={board.isError}
      now={c.now}
    >
      {board.data ? (
        <>
          <span className="home-big mono home-ok">
            {running}/{rows.length}
          </span>
          <span className="home-sub">
            <IconRunning /> {t('home.running', { count: running })}
          </span>
          {ready > 0 && (
            <span className="status-pill info">
              <IconReady /> {t('home.toUnload', { count: ready })}
            </span>
          )}
          {down > 0 && (
            <span className="status-pill danger">
              <IconMachineDown /> {t('home.down', { count: down })}
            </span>
          )}
        </>
      ) : (
        <Loading />
      )}
    </Tile>
  );
}

function MachinesDownTile({ c }: { c: Ctx }) {
  const { t } = useTranslation();
  const names = useLocalNames();
  const labeler = useReasonLabeler();
  const status = useMachineStatus(c.plantId);
  const down = (status.data ?? []).filter((m) => m.status === 'down' && m.active);
  const shown = down.slice(0, 3);
  return (
    <Tile
      to="/control/machines"
      icon={<IconMachineDown size="1.5em" />}
      title={t('home.machinesDown')}
      tone={down.length > 0 ? 'danger' : 'ok'}
      wide={down.length > 0}
      updatedAt={status.dataUpdatedAt}
      isFetching={status.isFetching}
      isError={status.isError}
      now={c.now}
    >
      {!status.data ? (
        <Loading />
      ) : down.length === 0 ? (
        <span className="home-sub">
          <IconReady /> {t('home.allWorking')}
        </span>
      ) : (
        <>
          <span className="home-big mono home-danger">{down.length}</span>
          <span className="home-list">
            {shown.map((m) => {
              // Home shows only the plant's preset label; the free-text detail stays on the
              // board and machine screens (coordinator 2026-11-06).
              const why = m.reason_code ? labeler(m.reason_code, m.reason_label_i18n) : null;
              return (
                <span key={m.machine_id} className="home-list-row">
                  <strong>{names.machine(m.machine_name, m.machine_name_i18n)}</strong>
                  {why && <span> · {why}</span>}
                </span>
              );
            })}
            {down.length > shown.length && (
              <span className="home-sub">
                {t('home.andMore', { count: down.length - shown.length })}
              </span>
            )}
          </span>
        </>
      )}
    </Tile>
  );
}

function NextTruckTile({ c }: { c: Ctx }) {
  const { t, i18n } = useTranslation();
  const plant = usePlant(c.plantId);
  const board = useLoadOutBoard(c.plantId);
  const tz = plant.data?.timezone ?? 'America/New_York';
  const data = board.data;
  const serverNow = estimateServerNow(data?.server_time, board.dataUpdatedAt, c.now);
  const next = data ? nextTruck(data.routes, data.load_date, serverNow, tz) : null;
  const total = data?.routes.length ?? 0;
  const done = data?.routes.filter((r) => r.loaded).length ?? 0;
  const mins = next ? minutesUntil(data?.load_date ?? '', next.route.load_time, serverNow, tz) : 0;
  // Compact so it fits one line in a half-width tile: "5h 28m" / "18m".
  const dur = (m: number) =>
    Math.abs(m) >= 60
      ? t('home.hm', { h: Math.floor(Math.abs(m) / 60), m: Math.abs(m) % 60 })
      : t('home.m', { m: Math.abs(m) });
  const tone: TileTone =
    total === 0
      ? 'neutral'
      : next === null
        ? 'info'
        : mins < 0
          ? 'danger'
          : mins <= 30
            ? 'warn'
            : 'info';
  return (
    <Tile
      to="/control/load-out"
      icon={<IconTruck size="1.5em" />}
      title={t('loadOut.nextLabel')}
      tone={tone}
      updatedAt={board.dataUpdatedAt}
      isFetching={board.isFetching}
      isError={board.isError}
      now={c.now}
    >
      {!data ? (
        <Loading />
      ) : total === 0 ? (
        <span className="home-sub">{t('loadOut.noRoutes')}</span>
      ) : next === null ? (
        <span className="home-sub home-info">
          <IconReady /> {t('loadOut.allLoaded')}
        </span>
      ) : (
        <>
          <span className="home-mid head">{localRouteName(next.route.name, i18n.language)}</span>
          <span
            className={`home-big mono ${mins < 0 ? 'home-danger' : mins <= 30 ? 'home-warn' : 'home-info'}`}
          >
            {dur(mins)}
          </span>
          <span className="home-sub">
            {mins < 0 && <IconWarning />} {mins < 0 ? t('loadOut.lateWord') : t('loadOut.leftWord')}
          </span>
        </>
      )}
      {data && total > 0 && (
        <span className="home-sub">{t('loadOut.progress', { done, total })}</span>
      )}
    </Tile>
  );
}

function TasksTile({ c }: { c: Ctx }) {
  const { t } = useTranslation();
  const tasks = useTasks(c.plantId, false);
  const open = (tasks.data ?? []).filter((x) => !x.done_at).length;
  return (
    <Tile
      to="/control/tasks"
      icon={<IconTasks size="1.5em" />}
      title={c.isOwner ? t('tasks.title') : t('tasks.myTitle')}
      tone={open > 0 ? 'warn' : 'neutral'}
      updatedAt={tasks.dataUpdatedAt}
      isFetching={tasks.isFetching}
      isError={tasks.isError}
      now={c.now}
    >
      {!tasks.data ? (
        <Loading />
      ) : (
        <>
          <span className={`home-big mono ${open > 0 ? 'home-warn' : ''}`}>{open}</span>
          <span className="home-sub">
            {c.isOwner
              ? t('home.tasksOpen', { count: open })
              : t('home.myTasksOpen', { count: open })}
          </span>
        </>
      )}
    </Tile>
  );
}

function DirtyWorkTile({ c }: { c: Ctx }) {
  const { t, i18n } = useTranslation();
  // The same selector and numbers as the owner's "Dirty work out there" card (review §3).
  const dirty = useDirtyWork(c.plantId);
  const text = useDirtyText();
  const customerName = useCustomerNameOf();
  const d = dirty.data;
  const doneAt =
    d && dirty.capacityReady && d.time.minutes !== null && d.time.minutes > 0
      ? new Intl.DateTimeFormat(i18n.language, { hour: 'numeric', minute: '2-digit' }).format(
          new Date(c.now + roundedMinutes(d.time.minutes) * 60_000),
        )
      : null;
  const timeText = d && dirty.capacityReady ? text.time(d.time) : null;
  const aa = d && dirty.queueReady ? d.customers.filter((x) => x.items > 0) : [];
  return (
    <Tile
      to="/control/estimates"
      icon={<IconBins size="1.5em" />}
      title={t('dirty.tileTitle')}
      wide
      updatedAt={dirty.current.dataUpdatedAt}
      isFetching={dirty.current.isFetching}
      isError={dirty.current.isError}
      now={c.now}
    >
      {dirty.error && !d ? (
        <span className="home-sub">
          <IconWarning /> {t(errorMessageKey(dirty.error))}
        </span>
      ) : !d ? (
        <Loading />
      ) : (
        <>
          <span className="home-big mono">
            {d.ours.categories.length === 0
              ? `0 ${t('dirty.loadsWord')}`
              : text.loads(d.ours.loads, d.ours.unknown)}
          </span>
          {timeText && <span className="home-sub home-muted">{timeText}</span>}
          {doneAt && <span className="home-sub">{t('home.doneAround', { time: doneAt })}</span>}
          {d.ours.categories.length > 0 && (
            <span className="home-cats">
              {d.ours.categories.map((cat) => (
                <span key={cat.category} className="home-cat">
                  <strong>{t(`categories.${cat.category}`)}</strong>{' '}
                  <span>{text.amounts(cat.amounts)}</span>{' '}
                  <span className="home-muted">{text.loads(cat.loads, cat.unknown)}</span>
                </span>
              ))}
            </span>
          )}
          {aa.map((x) => (
            <span key={x.customerId} className="home-sub">
              {t('dirty.queueCustomer', {
                name:
                  customerName(dirty.customerGroupId.get(x.customerId)) ?? t('customers.generic'),
                loads: text.loads(x.loads, x.unknown),
              })}
            </span>
          ))}
          {d.notEstimated > 0 && (
            <span className="home-sub home-muted">
              {t('dirty.notEstimated', { count: d.notEstimated })}
            </span>
          )}
        </>
      )}
    </Tile>
  );
}

function QueueTile({ c }: { c: Ctx }) {
  const { t } = useTranslation();
  const localized = useLocalizedName();
  const queue = useQueue(c.washroomId);
  const items = queue.data ?? [];
  const rush = items.filter((i) => i.is_rush).length;
  // Board order: the first item is what the washers take next (review: no loads number here).
  const next = items[0];
  return (
    <Tile
      to="/control/queue"
      icon={<IconQueue size="1.5em" />}
      title={t('nav.queue')}
      tone={rush > 0 ? 'warn' : 'neutral'}
      updatedAt={queue.dataUpdatedAt}
      isFetching={queue.isFetching}
      isError={queue.isError}
      now={c.now}
    >
      {!queue.data ? (
        <Loading />
      ) : (
        <>
          <span className="home-big mono">{items.length}</span>
          <span className="home-sub">
            {next
              ? t('home.queueNext', {
                  count: items.length,
                  name: localized(next.wash_group_name, next.wash_group_name_i18n),
                })
              : t('home.queueItems', { count: items.length })}
          </span>
          {rush > 0 && (
            <span className="status-pill warn">
              <IconRush /> {t('home.rush', { count: rush })}
            </span>
          )}
        </>
      )}
    </Tile>
  );
}

export function HomeTile({ id, ctx }: { id: TileId; ctx: Ctx }) {
  switch (id) {
    case 'washers':
      return <WashersTile c={ctx} />;
    case 'machinesDown':
      return <MachinesDownTile c={ctx} />;
    case 'nextTruck':
      return <NextTruckTile c={ctx} />;
    case 'tasks':
      return <TasksTile c={ctx} />;
    case 'dirtyWork':
      return <DirtyWorkTile c={ctx} />;
    case 'queue':
      return <QueueTile c={ctx} />;
  }
}
