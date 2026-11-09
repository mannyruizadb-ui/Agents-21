import { useState } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useLocalNames } from '../../lib/seededNames';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow } from '../../lib/useNow';
import { DataAge } from './DataAge';
import { IconIdle, IconMachineDown, IconReady, IconRunning, IconRush, IconWarning } from './Icons';
import { QueueBadges } from './QueueBadges';
import { useQtyText } from './useQtyText';
import { GroupChip } from './GroupChip';
import { errorMessageKey } from './rpcError';
import { estimateServerNow, minutesLeftRoundedUp, minutesSinceEnd, washerNow } from './washerTime';
import { reasonText } from './machineReason';
import { useReasonLabeler } from './downReasons';
import { TapAlarmBanner } from './TapAlarmBanner';
import {
  pickArea,
  useAreas,
  useMachineStatus,
  useQueue,
  useWashGroups,
  useWashroomBoard,
  type QueueRow,
  type WasherBoardRow,
  type WashGroupRow,
} from './washroomData';
import { nextUnassigned } from '../queue/queueOrder';
import { boardLoadsLeft, queueLoadsLeft } from '../dirtyWork/dirtyWork';
import { useTapSync } from './useTapSync';
import '../../lib/forms.css';
import './washroom.css';
import './board.css';

// Washer board (PRD D1/G6; owner-approved Stitch style 2026-11-06): the home tab for owners and
// managers. A NEXT IN QUEUE banner, a 2-column tile grid (status pill + group chip + big countdown),
// and a strip of other machines that are out of service. Real data only; no names, no weights.
// Live: refetch on mount, focus, online, visibilitychange and every 30 s; Realtime is never relied on.

function Tile({
  row,
  fetchedAt,
  now,
  groups,
}: {
  row: WasherBoardRow;
  fetchedAt: number;
  now: number;
  groups: ReadonlyMap<string, WashGroupRow>;
}) {
  const { t } = useTranslation();
  const names = useLocalNames();
  const qtyText = useQtyText();
  const labeler = useReasonLabeler();
  const view = washerNow(row.status, row.expected_end_at, row.server_time, fetchedAt, now);
  const serverNow = estimateServerNow(row.server_time, fetchedAt, now);
  const headingId = `washer-${row.machine_id}`;
  const isDown = !!row.is_down;

  if (isDown) {
    const why = reasonText(row.down_reason_code, row.down_reason, (c) =>
      labeler(c, row.down_reason_label_i18n),
    );
    const mins = minutesSinceEnd(row.down_since, serverNow);
    return (
      <li className="wb-tile down stripes-danger" aria-labelledby={headingId}>
        <Link to={`/control/machines?machine=${row.machine_id}`} className="wb-tile-link">
          <span className="wb-tile-head">
            <span id={headingId} className="wb-name">
              {names.machine(row.machine_name)}
            </span>
            <span className="status-pill danger">
              <IconMachineDown /> {t('board.pill.down')}
            </span>
          </span>
          {why && <span className="wb-down-why">{why}</span>}
          {mins !== null && (
            <span className="wb-meta mono">
              {mins < 1
                ? t('common.justNow')
                : mins < 60
                  ? t('board.forMinutes', { count: mins })
                  : t('board.forHours', { h: Math.floor(mins / 60), m: mins % 60 })}
            </span>
          )}
        </Link>
      </li>
    );
  }

  const cycle = (row.cycle_minutes ?? 0) * 60;
  const progress =
    view.left !== null && cycle > 0 ? Math.min(1, Math.max(0, 1 - view.left / cycle)) : 0;
  const pill =
    view.status === 'running' ? (
      <span className="status-pill ok">
        <IconRunning /> {t('board.pill.running')}
      </span>
    ) : view.status === 'ready' ? (
      <span className="status-pill warn">
        <IconReady /> {t('board.pill.ready')}
      </span>
    ) : view.status === 'idle' ? (
      <span className="status-pill idle">
        <IconIdle /> {t('board.pill.idle')}
      </span>
    ) : (
      <span className="status-pill idle">
        <IconWarning /> {t('board.pill.unknown')}
      </span>
    );

  return (
    <li className={`wb-tile ${view.status}`} aria-labelledby={headingId}>
      <Link to={`/station/washer/${row.machine_id}`} className="wb-tile-link">
        <span className="wb-tile-head">
          <span id={headingId} className="wb-name">
            {names.machine(row.machine_name)}
          </span>
          {pill}
        </span>
        {row.cycle_id ? (
          <GroupChip
            name={row.wash_group_name}
            nameI18n={row.wash_group_name_i18n}
            colorHex={row.wash_group_color_hex}
            washGroupId={row.wash_group_id}
          />
        ) : view.status === 'idle' ? null : (
          // The EMPTY pill already says it for an idle washer; this covers "unknown".
          <span className="wb-empty">{t('washroom.empty')}</span>
        )}
        {row.cycle_id && row.is_rewash && (
          <span>
            <QueueBadges rewash />
          </span>
        )}
        {view.status === 'running' && view.left !== null && (
          <>
            <span className="wb-timer">
              <span className="mono wb-big" aria-hidden="true">
                {minutesLeftRoundedUp(view.left)}
              </span>
              <span className="wb-unit">{t('board.minLeft')}</span>
              <span className="visually-hidden">
                {t('washroom.minutesLeft', { count: minutesLeftRoundedUp(view.left) })}
              </span>
            </span>
            <span className="wb-bar" aria-hidden="true">
              <span style={{ width: `${Math.round(progress * 100)}%` }} />
            </span>
          </>
        )}
        {view.status === 'ready' && (
          // The UNLOAD pill names the state; the tile adds only how long it has waited.
          <span className="wb-ready">
            {view.readyMinutes !== null && (
              <span className="mono">
                {t('washroom.waitingMinutes', { count: view.readyMinutes })}
              </span>
            )}
          </span>
        )}
        {row.cycle_id && row.formula_external_no && view.status !== 'ready' && (
          <span className="wb-meta mono">
            {row.cycle_minutes !== null
              ? t('washroom.formulaValue', {
                  no: row.formula_external_no,
                  minutes: row.cycle_minutes,
                })
              : t('washroom.formulaOnly', { no: row.formula_external_no })}
          </span>
        )}
        {row.next_queue_item_id && row.next_is_assigned && (
          <span className="wb-next">
            <span className="wb-next-label">{t('washroom.next')}</span>
            <GroupChip
              name={row.next_wash_group_name}
              nameI18n={row.next_wash_group_name_i18n}
              colorHex={row.next_wash_group_color_hex}
              washGroupId={row.next_wash_group_id}
            />
            <span className="wb-meta">
              {qtyText(
                boardLoadsLeft(
                  row.next_loads_remaining,
                  row.next_unit,
                  groups.get(row.next_wash_group_id ?? ''),
                ),
                row.next_qty,
                row.next_unit,
              )}
            </span>
          </span>
        )}
        {/* The whole tile is the link; a chevron (not "Open" on every tile) marks it. */}
        <span className="wb-open" aria-hidden="true">
          ›
        </span>
      </Link>
    </li>
  );
}

/** The queue's next unassigned work, shown ONCE (any free washer takes the top item). */
function NextInQueue({ items }: { items: QueueRow[] }) {
  const { t } = useTranslation();
  const qtyText = useQtyText();
  const { shown, more } = nextUnassigned(items, 3);
  const top = shown[0];
  return (
    <Link
      to="/control/queue"
      className={top?.is_rush ? 'wb-next-banner rush stripes-warn' : 'wb-next-banner'}
      aria-labelledby="next-in-queue"
    >
      <span className="wb-next-icon" aria-hidden="true">
        <IconRush size="28" />
      </span>
      <span className="wb-next-body">
        <span id="next-in-queue" className="head wb-next-title">
          {t('washroom.nextInQueue')}
        </span>
        {top ? (
          <>
            <span className="wb-next-line">
              {top.is_rush && (
                <span className="status-pill warn">
                  <IconRush /> {t('queue.rush')}
                </span>
              )}
              {top.is_rewash && <QueueBadges rewash />}
            </span>
            <GroupChip
              name={top.wash_group_name}
              nameI18n={top.wash_group_name_i18n}
              colorHex={top.wash_group_color_hex}
              washGroupId={top.wash_group_id}
            />
            <span className="wb-meta">{qtyText(queueLoadsLeft(top), top.qty, top.unit)}</span>
            {shown.length > 1 && (
              <span className="wb-meta">
                {t('board.thenMore', { count: shown.length - 1 + more })}
              </span>
            )}
          </>
        ) : (
          <span>{t('washroom.noUnassigned')}</span>
        )}
      </span>
      <span aria-hidden="true" className="wb-chevron">
        ›
      </span>
    </Link>
  );
}

export function WasherBoardPage() {
  const { t } = useTranslation();
  const names = useLocalNames();
  const now = useNow(1000);
  const areas = useAreas();
  const [areaId, setAreaId] = useState<string | null>(null);
  const washrooms = (areas.data ?? []).filter((a) => a.kind === 'washroom');
  const area = pickArea(washrooms, 'washroom', areaId);
  const board = useWashroomBoard(area?.id);
  useLiveRefetch(board.refetch, !!area);
  const queue = useQueue(area?.id);
  // Factors per group: a NEXT without one says "loads unknown", never "≈ 0" (review item 2).
  const washGroups = useWashGroups(area?.plant_id);
  const groupById = new Map((washGroups.data ?? []).map((g) => [g.id, g]));
  useLiveRefetch(queue.refetch, !!area);
  const taps = useTapSync();
  const machines = useMachineStatus(area?.plant_id);
  useLiveRefetch(machines.refetch, !!area);
  const labeler = useReasonLabeler();
  const boardIds = new Set((board.data ?? []).map((r) => r.machine_id));
  const otherDown = (machines.data ?? []).filter(
    (m) => m.status === 'down' && !boardIds.has(m.machine_id),
  );
  const machinesServerNow = estimateServerNow(
    machines.data?.[0]?.server_time,
    machines.dataUpdatedAt,
    now,
  );
  const rows = board.data ?? [];
  const running = rows.filter(
    (r) =>
      !r.is_down &&
      washerNow(r.status, r.expected_end_at, r.server_time, board.dataUpdatedAt, now).status ===
        'running',
  ).length;

  return (
    <main className="form-page wb-page">
      <header className="wb-header">
        <h1>{t('washroom.boardTitle')}</h1>
        {rows.length > 0 && (
          <span className="wb-count mono">
            {t('board.running', { n: running, total: rows.length })}
          </span>
        )}
      </header>
      {washrooms.length > 1 && (
        <div className="field">
          <label htmlFor="area">{t('washroom.areaLabel')}</label>
          <select id="area" value={area?.id ?? ''} onChange={(e) => setAreaId(e.target.value)}>
            {washrooms.map((a) => (
              <option key={a.id} value={a.id}>
                {names.area(a.name)}
              </option>
            ))}
          </select>
        </div>
      )}
      <DataAge
        updatedAt={board.dataUpdatedAt}
        now={now}
        isFetching={board.isFetching}
        isError={board.isError && !!board.data}
      />
      <TapAlarmBanner />
      <div role="status" aria-live="polite">
        {taps.pending.length > 0 && (
          <p className="notice">{t('station.pendingCount', { count: taps.pending.length })}</p>
        )}
      </div>
      {(areas.isPending || (area && board.isPending)) && <p role="status">{t('common.loading')}</p>}
      {areas.isSuccess && !area && <p>{t('washroom.noWashroom')}</p>}
      {board.isError && !board.data && (
        <div role="alert">
          <p className="error">{t(errorMessageKey(board.error))}</p>
          <button type="button" onClick={() => void board.refetch()}>
            {t('common.tryAgain')}
          </button>
        </div>
      )}
      {queue.data && <NextInQueue items={queue.data} />}
      {queue.isError && !queue.data && <p className="error">{t(errorMessageKey(queue.error))}</p>}
      {board.data && rows.length === 0 && <p>{t('washroom.noWashers')}</p>}
      {rows.length > 0 && (
        <ul className="wb-grid">
          {rows.map((row) => (
            <Tile
              key={row.machine_id}
              row={row}
              fetchedAt={board.dataUpdatedAt}
              now={now}
              groups={groupById}
            />
          ))}
        </ul>
      )}
      {otherDown.length > 0 && (
        <section aria-labelledby="other-down">
          <h2 id="other-down" className="wb-section">
            <IconMachineDown /> {t('machines.otherDown')}
          </h2>
          <ul className="wb-strip">
            {otherDown.map((m) => {
              const why = reasonText(m.reason_code, m.reason, (c) =>
                labeler(c, m.reason_label_i18n),
              );
              const mins = minutesSinceEnd(m.since, machinesServerNow);
              return (
                <li key={m.machine_id} className="wb-strip-card stripes-danger">
                  <Link to={`/control/machines?machine=${m.machine_id}`}>
                    <span className="wb-name">{names.machine(m.machine_name)}</span>
                    <span className="status-pill danger">
                      <IconMachineDown /> {t('board.pill.down')}
                    </span>
                    {why && <span className="wb-down-why">{why}</span>}
                    {mins !== null && (
                      <span className="wb-meta mono">
                        {mins < 1
                          ? t('common.justNow')
                          : mins < 60
                            ? t('board.forMinutes', { count: mins })
                            : t('board.forHours', { h: Math.floor(mins / 60), m: mins % 60 })}
                      </span>
                    )}
                  </Link>
                </li>
              );
            })}
          </ul>
        </section>
      )}
      <p>
        <Link className="button-link secondary" to="/control/machines">
          <IconMachineDown /> {t('machines.linkLabel')}
        </Link>
      </p>
    </main>
  );
}
