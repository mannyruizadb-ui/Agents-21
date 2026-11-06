import { useRef, useState } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { supabase } from '../../lib/supabase';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow } from '../../lib/useNow';
import { DataAge } from '../washroom/DataAge';
import { IconReady, IconWarning } from '../washroom/Icons';
import { useLocalizedName } from '../washroom/localizedName';
import { errorMessageKey, unwrap } from '../washroom/rpcError';
import { estimateServerNow } from '../washroom/washerTime';
import { useAreas } from '../washroom/washroomData';
import { nextTruck } from './loadOutLogic';
import {
  useLoadOutBoard,
  useLoadOutPermissions,
  usePlant,
  type BoardLine,
  type BoardRoute,
  type BoardTotal,
} from './loadOutData';
import '../../lib/forms.css';
import './loadout.css';

// Load-out board (owner 2026-11-06): what each truck takes, in load-time order, for the manager on duty
// (03:30–05:30). The owner or the manager on duty taps "Loaded ✓" per route (Undo fixes a mistake);
// everyone else reads it. Live: refetch on focus/online/visibility and every 30 s; data age shown.

function useQtyLabel() {
  const { t } = useTranslation();
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
    const qty = line.special_text
      ? new Intl.NumberFormat().format(line.qty)
      : line.count_mode === 'pack'
        ? t('loadOut.packsOf', { count: line.qty, size: line.pack_size ?? '?' })
        : t('loadOut.pieces', { count: line.qty });
    return { name, qty };
  };
}

function RouteCard({
  route,
  loadDate,
  timeZone,
  canMark,
  onStatus,
}: {
  route: BoardRoute;
  loadDate: string;
  /** Plant time zone: "loaded at" reads in plant time, like the truck times. */
  timeZone: string;
  canMark: boolean;
  onStatus: (ok: boolean, text: string) => void;
}) {
  const { t, i18n } = useTranslation();
  const qc = useQueryClient();
  const label = useQtyLabel();
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
          ? t('loadOut.markedLoaded', { route: route.name })
          : t('loadOut.undone', { route: route.name }),
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

  return (
    <li
      className={route.loaded ? 'lo-board-card loaded' : 'lo-board-card'}
      aria-labelledby={headingId}
    >
      <h2 id={headingId}>
        <span className="lo-time">{route.load_time.slice(0, 5)}</span> {route.name}
      </h2>
      {route.lines.length === 0 ? (
        <p className="hint">{t('loadOut.nothingForRoute')}</p>
      ) : (
        <ul className="lo-lines">
          {route.lines.map((l) => {
            const x = label(l);
            return (
              <li key={l.line_id}>
                <span>{x.name}</span>
                <strong>{x.qty}</strong>
              </li>
            );
          })}
        </ul>
      )}
      {route.loaded ? (
        <div className="lo-done">
          <p>
            <IconReady />{' '}
            <strong>
              {t('loadOut.loadedAt', { time: route.loaded_since ? time(route.loaded_since) : '' })}
            </strong>
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
      ) : canMark ? (
        <button
          type="button"
          className="lo-loaded-button"
          disabled={mark.isPending}
          onClick={() => mark.mutate(true)}
        >
          {t('loadOut.loadedButton')}
        </button>
      ) : (
        <p className="hint">{t('loadOut.onlyOnDuty')}</p>
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
  useLiveRefetch(board.refetch, !!plantId);
  const label = useQtyLabel();
  const [status, setStatus] = useState<{ ok: boolean; text: string } | null>(null);
  const tz = plant.data?.timezone ?? 'America/New_York';
  const data = board.data;
  const serverNow = estimateServerNow(data?.server_time, board.dataUpdatedAt, now);
  const next = data ? nextTruck(data.routes, data.load_date, serverNow, tz) : null;
  const canMark = perms.data?.canMarkLoaded ?? false;
  const fmtDate = (d: string) =>
    new Intl.DateTimeFormat(i18n.language, {
      weekday: 'long',
      month: 'short',
      day: 'numeric',
      timeZone: 'UTC',
    }).format(new Date(`${d}T12:00:00Z`));

  return (
    <main className="form-page lo-page">
      <p>
        <Link to="/control">{t('common.back')}</Link>
      </p>
      <h1>{t('loadOut.boardTitle')}</h1>
      {data && <p className="lo-date">{fmtDate(data.load_date)}</p>}
      <DataAge
        updatedAt={board.dataUpdatedAt}
        now={now}
        isFetching={board.isFetching}
        isError={board.isError && !!data}
      />
      {board.isPending && <p role="status">{t('common.loading')}</p>}
      {board.isError && !data && <p className="error">{t(errorMessageKey(board.error))}</p>}

      {data && data.routes.length > 0 && (
        <p className={next && next.minutes < 0 ? 'lo-countdown late' : 'lo-countdown'}>
          {next === null ? (
            <>
              <IconReady /> {t('loadOut.allLoaded')}
            </>
          ) : next.minutes < 0 ? (
            <>
              <IconWarning /> {t('loadOut.late', { route: next.route.name, count: -next.minutes })}
            </>
          ) : (
            t('loadOut.nextTruck', {
              route: next.route.name,
              time: next.route.load_time.slice(0, 5),
              when:
                next.minutes >= 60
                  ? t('loadOut.inHours', { h: Math.floor(next.minutes / 60), m: next.minutes % 60 })
                  : t('loadOut.inMinutes', { count: next.minutes }),
            })
          )}
        </p>
      )}

      {data && data.totals.length > 0 && (
        <section className="card" aria-labelledby="lo-totals">
          <h2 id="lo-totals">{t('loadOut.totals')}</h2>
          <ul className="lo-lines">
            {data.totals.map((x) => {
              const v = label(x);
              return (
                <li key={x.item_type_id}>
                  <span>{v.name}</span>
                  <strong>{v.qty}</strong>
                </li>
              );
            })}
          </ul>
        </section>
      )}

      <div role="status" aria-live="polite">
        {status && <p className={status.ok ? 'notice' : 'error'}>{status.text}</p>}
      </div>
      {perms.isSuccess && !canMark && <p className="notice">{t('loadOut.onlyOnDutyNotice')}</p>}
      {data && data.routes.length === 0 && <p className="notice">{t('loadOut.noRoutes')}</p>}
      {data && (
        <ol className="lo-board">
          {data.routes.map((r) => (
            <RouteCard
              key={r.route_id}
              route={r}
              loadDate={data.load_date}
              timeZone={tz}
              canMark={canMark}
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
