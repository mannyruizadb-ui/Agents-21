import { useRef, useState } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { supabase } from '../../lib/supabase';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow } from '../../lib/useNow';
import { DataAge } from '../washroom/DataAge';
import { IconReady, IconTruck, IconWarning } from '../washroom/Icons';
import { useLocalizedName } from '../washroom/localizedName';
import { errorMessageKey, unwrap } from '../washroom/rpcError';
import { estimateServerNow } from '../washroom/washerTime';
import { useAreas } from '../washroom/washroomData';
import { localRouteName, minutesUntil, nextTruck, wallClock } from './loadOutLogic';
import {
  useLoadOutBoard,
  useLoadOutPermissions,
  useMatCatalog,
  usePlant,
  type BoardLine,
  type BoardRoute,
  type BoardTotal,
  type MatItem,
} from './loadOutData';
import { matIndex, matPieces, matSections, matTotals } from './matTotals';
import { MatTotalsLine } from './MatTotalsLine';
import '../../lib/forms.css';
import './loadout.css';

// Load-out board (owner 2026-11-06; redesign 2026-11-06): what each truck takes, in load-time order,
// for the manager on duty (03:30–05:30). A "next truck" countdown on top, tonight's totals, then one
// card per route with its own time left. The owner or the manager on duty taps "Loaded ✓" per route
// (one tap per route, owner: "must be simple"; Undo fixes a mistake); everyone else reads it.
// Loaded = blue (done), soon = amber, late = red + icon + words. No bays, drivers or checklists.
// Live: refetch on focus/online/visibility and every 30 s; data age shown.
// Mats (owner 2026-11-09, "by all 3"): per route and in tonight's totals as totals by size + total;
// the colour and item detail opens on tap.

type MatIdx = ReadonlyMap<string, { item: MatItem; size: string | null; groupId: string }>;

/** A set of lines' mats by size, from the mat catalog (pieces; pack items × pack size). */
function linesMatTotals(
  lines: readonly { item_type_id: string | null; qty: number }[],
  idx: MatIdx,
) {
  return matTotals(
    lines.flatMap((l) => {
      const m = l.item_type_id ? idx.get(l.item_type_id) : undefined;
      return m ? [{ size: m.size, pieces: matPieces(m.item, l.qty) }] : [];
    }),
  );
}

/** Mats of a route: totals by size, the item detail behind one tap. */
function RouteMats({ lines, idx }: { lines: BoardLine[]; idx: MatIdx }) {
  const { t } = useTranslation();
  const label = useQtyLabel();
  const mats = lines.filter((l) => l.item_type_id && idx.has(l.item_type_id));
  if (mats.length === 0) return null;
  return (
    <div className="lo-board-mats">
      <p className="lo-board-mats-title">{t('loadOut.mats.title')}</p>
      <MatTotalsLine totals={linesMatTotals(mats, idx)} />
      <details className="lo-mat-detail">
        <summary>{t('loadOut.mats.detail', { count: mats.length })}</summary>
        <ul className="lo-lines">
          {mats.map((l) => {
            const x = label(l);
            return (
              <li key={l.line_id}>
                <span>{x.name}</span>
                <strong className="mono">{x.qty}</strong>
              </li>
            );
          })}
        </ul>
      </details>
    </div>
  );
}

function useQtyLabel() {
  const { i18n } = useTranslation();
  const localized = useLocalizedName();
  return (
    line: Pick<
      BoardLine | BoardTotal,
      'item_name' | 'item_name_i18n' | 'count_mode' | 'pack_size' | 'qty'
    > & {
      special_text?: string | null;
    },
  ) => {
    const name = line.special_text ?? localized(line.item_name ?? '', line.item_name_i18n);
    // Owner 2026-11-10: just the number ("Sheets 500"). Every load-out number is pieces, as typed
    // from the invoice; the crew knows the pack sizes.
    const qty = new Intl.NumberFormat(i18n.language).format(line.qty);
    return { name, qty };
  };
}

/** "18 min" / "1 h 48 min" (no sign). */
function useDuration() {
  const { t } = useTranslation();
  return (mins: number) => {
    const m = Math.abs(mins);
    return m >= 60
      ? t('loadOut.hoursMin', { h: Math.floor(m / 60), m: m % 60 })
      : t('loadOut.minutes', { count: m });
  };
}

const SOON_MIN = 30;

function TimePill({ loaded, minutes }: { loaded: boolean; minutes: number }) {
  const { t } = useTranslation();
  const dur = useDuration();
  if (loaded)
    return (
      <span className="status-pill info">
        <IconReady /> {t('loadOut.pill.loaded')}
      </span>
    );
  if (minutes < 0)
    return (
      <span className="status-pill danger">
        <IconWarning /> {t('loadOut.pill.late', { when: dur(minutes) })}
      </span>
    );
  return (
    <span className={minutes <= SOON_MIN ? 'status-pill warn' : 'status-pill idle'}>
      {t('loadOut.pill.in', { when: dur(minutes) })}
    </span>
  );
}

function RouteCard({
  route,
  loadDate,
  timeZone,
  minutes,
  isNext,
  canMark,
  matIdx,
  onStatus,
}: {
  route: BoardRoute;
  matIdx: MatIdx;
  loadDate: string;
  /** Plant time zone: "loaded at" reads in plant time, like the truck times. */
  timeZone: string;
  minutes: number;
  isNext: boolean;
  canMark: boolean;
  onStatus: (ok: boolean, text: string) => void;
}) {
  const { t, i18n } = useTranslation();
  const qc = useQueryClient();
  const label = useQtyLabel();
  const routeName = localRouteName(route.name, i18n.language);
  // One client_id per attempt, reused on retry until it succeeds (idempotent on the server).
  const clientId = useRef<string | null>(null);
  const mark = useMutation({
    mutationFn: async (loaded: boolean) => {
      clientId.current ??= crypto.randomUUID();
      return unwrap(
        await supabase.rpc('mark_route_loaded', {
          p_route_id: route.route_id,
          p_load_date: loadDate,
          p_client_id: clientId.current,
          p_loaded: loaded,
        }),
      );
    },
    onSuccess: (_r, loaded) => {
      clientId.current = null;
      onStatus(
        true,
        loaded
          ? t('loadOut.markedLoaded', { route: routeName })
          : t('loadOut.undone', { route: routeName }),
      );
    },
    onError: (e) => onStatus(false, t(errorMessageKey(e))),
    onSettled: () => void qc.invalidateQueries({ queryKey: ['load-out-board'] }),
  });
  const time = (iso: string) =>
    new Intl.DateTimeFormat(i18n.language, { hour: 'numeric', minute: '2-digit', timeZone }).format(
      new Date(iso),
    );
  const headingId = `route-${route.route_id}`;
  const classes = ['lo-board-card'];
  if (route.loaded) classes.push('loaded');
  else if (minutes < 0) classes.push('late');
  else if (isNext) classes.push('next');

  const others = route.lines.filter((l) => !(l.item_type_id && matIdx.has(l.item_type_id)));
  const lines =
    route.lines.length === 0 ? (
      <p className="hint">{t('loadOut.nothingForRoute')}</p>
    ) : (
      <>
        {others.length > 0 && (
          <ul className="lo-lines">
            {others.map((l) => {
              const x = label(l);
              return (
                <li key={l.line_id} className={l.special_text ? 'special' : undefined}>
                  <span>
                    {x.name}
                    {l.entered_by_name && (
                      <span className="hint"> · {t('names.by', { name: l.entered_by_name })}</span>
                    )}
                  </span>
                  <strong className="mono">{x.qty}</strong>
                </li>
              );
            })}
          </ul>
        )}
        <RouteMats lines={route.lines} idx={matIdx} />
      </>
    );

  return (
    <li className={classes.join(' ')} aria-labelledby={headingId}>
      <div className="lo-card-head">
        <h2 id={headingId} className="head">
          {routeName}
        </h2>
        <span className="lo-time-chip mono">{wallClock(route.load_time, i18n.language)}</span>
      </div>
      <p className="lo-card-pill">
        <TimePill loaded={route.loaded} minutes={minutes} />
      </p>
      {route.loaded ? (
        <>
          <details className="lo-loaded-items">
            <summary>{t('loadOut.showItems', { count: route.lines.length })}</summary>
            {lines}
          </details>
          <div className="lo-done">
            <p>
              <IconReady />{' '}
              <strong>
                {t('loadOut.loadedAt', {
                  time: route.loaded_since ? time(route.loaded_since) : '',
                })}
              </strong>
              {route.loaded_by_name && <> · {t('names.by', { name: route.loaded_by_name })}</>}
            </p>
            {canMark && (
              <button
                type="button"
                className="secondary"
                disabled={mark.isPending}
                onClick={() => mark.mutate(false)}
              >
                {t('loadOut.undo')}
              </button>
            )}
          </div>
        </>
      ) : (
        <>
          {lines}
          {canMark ? (
            <button
              type="button"
              className="lo-loaded-button"
              disabled={mark.isPending}
              onClick={() => mark.mutate(true)}
            >
              <IconTruck /> {t('loadOut.loadedButton')}
            </button>
          ) : (
            <p className="hint">{t('loadOut.onlyOnDuty')}</p>
          )}
        </>
      )}
    </li>
  );
}

export function LoadOutBoardPage() {
  const { t, i18n } = useTranslation();
  const session = useRequiredSession();
  const now = useNow(15_000);
  const areas = useAreas();
  const plantId = areas.data?.[0]?.plant_id;
  const plant = usePlant(plantId);
  const perms = useLoadOutPermissions(session.user.id, plant.data ?? undefined);
  const board = useLoadOutBoard(plantId);
  const matCatalog = useMatCatalog(plantId);
  const matIdx: MatIdx = matCatalog.data
    ? matIndex(matSections(matCatalog.data.groups, matCatalog.data.items))
    : new Map();
  useLiveRefetch(board.refetch, !!plantId);
  const label = useQtyLabel();
  const dur = useDuration();
  const [status, setStatus] = useState<{ ok: boolean; text: string } | null>(null);
  const tz = plant.data?.timezone ?? 'America/New_York';
  const data = board.data;
  const serverNow = estimateServerNow(data?.server_time, board.dataUpdatedAt, now);
  const next = data ? nextTruck(data.routes, data.load_date, serverNow, tz) : null;
  const canMark = perms.data?.canMarkLoaded ?? false;
  const total = data?.routes.length ?? 0;
  const done = data?.routes.filter((r) => r.loaded).length ?? 0;
  const fmtDate = (d: string) =>
    new Intl.DateTimeFormat(i18n.language, {
      weekday: 'long',
      month: 'short',
      day: 'numeric',
      timeZone: 'UTC',
    }).format(new Date(`${d}T12:00:00Z`));

  const heroClass =
    next === null
      ? 'lo-next all-done'
      : next.minutes < 0
        ? 'lo-next late stripes-danger'
        : next.minutes <= SOON_MIN
          ? 'lo-next soon'
          : 'lo-next';

  return (
    <main className="form-page lo-page">
      <div className="lo-head">
        <h1>{t('loadOut.boardTitle')}</h1>
        {total > 0 && (
          <span className="lo-count head">{t('loadOut.loadedCount', { done, total })}</span>
        )}
      </div>
      {data && <p className="lo-date">{fmtDate(data.load_date)}</p>}
      <DataAge
        updatedAt={board.dataUpdatedAt}
        now={now}
        isFetching={board.isFetching}
        isError={board.isError && !!data}
      />
      {board.isPending && <p role="status">{t('common.loading')}</p>}
      {board.isError && !data && <p className="error">{t(errorMessageKey(board.error))}</p>}

      {data && total > 0 && (
        <section className={heroClass} aria-labelledby="lo-next-title">
          {next === null ? (
            <p id="lo-next-title" className="lo-next-all head">
              <IconReady size="1.4em" /> {t('loadOut.allLoaded')}
            </p>
          ) : (
            <>
              <div className="lo-next-main">
                <span className="lo-next-icon" aria-hidden="true">
                  {next.minutes < 0 ? <IconWarning size="1.6em" /> : <IconTruck size="1.6em" />}
                </span>
                <div>
                  <p className="lo-next-label">{t('loadOut.nextLabel')}</p>
                  <h2 id="lo-next-title" className="head">
                    {localRouteName(next.route.name, i18n.language)}
                  </h2>
                  <p className="lo-next-at">
                    {t('loadOut.truckAt', { time: wallClock(next.route.load_time, i18n.language) })}
                  </p>
                </div>
              </div>
              <p className="lo-next-countdown">
                <span className="mono lo-next-num">{dur(next.minutes)}</span>
                <span className="lo-next-unit">
                  {next.minutes < 0 ? t('loadOut.lateWord') : t('loadOut.leftWord')}
                </span>
              </p>
            </>
          )}
          <div className="lo-progress">
            <div
              className="lo-progress-bar"
              role="progressbar"
              aria-valuemin={0}
              aria-valuemax={total}
              aria-valuenow={done}
              aria-label={t('loadOut.progress', { done, total })}
            >
              <span style={{ width: `${total ? (done / total) * 100 : 0}%` }} />
            </div>
            <p>{t('loadOut.progress', { done, total })}</p>
          </div>
        </section>
      )}

      {data && data.totals.length > 0 && (
        <section aria-labelledby="lo-totals">
          <h2 id="lo-totals">{t('loadOut.totals')}</h2>
          <ul className="lo-totals">
            {data.totals
              .filter((x) => !matIdx.has(x.item_type_id))
              .map((x) => {
                const v = label(x);
                return (
                  <li key={x.item_type_id}>
                    <span className="lo-total-name">{v.name}</span>
                    <strong className="mono">{v.qty}</strong>
                  </li>
                );
              })}
          </ul>
          {data.totals.some((x) => matIdx.has(x.item_type_id)) && (
            <div className="lo-board-mats day">
              <p className="lo-board-mats-title">{t('loadOut.mats.title')}</p>
              <MatTotalsLine totals={linesMatTotals(data.totals, matIdx)} />
            </div>
          )}
        </section>
      )}

      <div role="status" aria-live="polite">
        {status && <p className={status.ok ? 'notice' : 'error'}>{status.text}</p>}
      </div>
      {perms.isSuccess && !canMark && <p className="notice">{t('loadOut.onlyOnDutyNotice')}</p>}
      {data && total === 0 && <p className="notice">{t('loadOut.noRoutes')}</p>}
      {data && total > 0 && <h2>{t('loadOut.routesTitle')}</h2>}
      {data && (
        <ol className="lo-board">
          {data.routes.map((r) => (
            <RouteCard
              key={r.route_id}
              route={r}
              loadDate={data.load_date}
              timeZone={tz}
              minutes={minutesUntil(data.load_date, r.load_time, serverNow, tz)}
              isNext={next?.route.route_id === r.route_id}
              canMark={canMark}
              matIdx={matIdx}
              onStatus={(ok, text) => setStatus({ ok, text })}
            />
          ))}
        </ol>
      )}
      {perms.data?.canEnter && (
        <p>
          <Link className="button-link secondary" to="/control/load-out/entry">
            {t('loadOut.entryTitle')}
          </Link>
        </p>
      )}
    </main>
  );
}
