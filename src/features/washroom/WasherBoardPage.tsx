import { useState } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow } from '../../lib/useNow';
import { DataAge } from './DataAge';
import { IconIdle, IconReady, IconRunning, IconWarning } from './Icons';
import { QueueBadges } from './QueueBadges';
import { useQtyText } from './useQtyText';
import { WashGroupLabel } from './WashGroupLabel';
import { errorMessageKey } from './rpcError';
import {
  estimateServerNow,
  formatCountdown,
  minutesLeftRoundedUp,
  washerNow,
  type WasherNow,
} from './washerTime';
import { DownBanner } from './DownBanner';
import {
  pickArea,
  useAreas,
  useMachineStatus,
  useQueue,
  useWashroomBoard,
  type QueueRow,
  type WasherBoardRow,
} from './washroomData';
import { nextUnassigned } from '../queue/queueOrder';
import { useTapSync } from './useTapSync';
import '../../lib/forms.css';
import './washroom.css';

// Washer board (PRD D1/G6 on the owner's and managers' phones): one card per active washer with
// NOW (group, countdown), NEXT, and the data's age. Live: refetch on mount, focus, online,
// visibilitychange and every 30 s; Realtime is never relied on.

function StatusLine({ view }: { view: WasherNow }) {
  const { t } = useTranslation();
  switch (view.status) {
    case 'running':
      return (
        <p className="status-line">
          <IconRunning />
          <span>{t('washroom.status.running')}</span>
          {view.left !== null && (
            <>
              <span aria-hidden="true">·</span>
              <span className="countdown" aria-hidden="true">
                {formatCountdown(view.left)}
              </span>
              <span className="visually-hidden">
                {t('washroom.minutesLeft', { count: minutesLeftRoundedUp(view.left) })}
              </span>
            </>
          )}
        </p>
      );
    case 'ready':
      return (
        <p className="status-line">
          <IconReady />
          <span>
            {t('washroom.status.ready')}
            {view.readyMinutes !== null &&
              ` · ${t('washroom.waitingMinutes', { count: view.readyMinutes })}`}
          </span>
        </p>
      );
    case 'idle':
      return (
        <p className="status-line">
          <IconIdle />
          <span>{t('washroom.status.idle')}</span>
        </p>
      );
    default:
      return (
        <p className="status-line">
          <IconWarning />
          <span>{t('washroom.status.unknown')}</span>
        </p>
      );
  }
}

function WasherCard({
  row,
  fetchedAt,
  now,
}: {
  row: WasherBoardRow;
  fetchedAt: number;
  now: number;
}) {
  const { t } = useTranslation();
  const qtyText = useQtyText();
  const view = washerNow(row.status, row.expected_end_at, row.server_time, fetchedAt, now);
  const headingId = `washer-${row.machine_id}`;
  // A down washer takes precedence over its cycle status (get_washroom_board, owner 2026-11-04).
  const isDown = !!row.is_down;
  return (
    <li
      className={`washer-card status-${isDown ? 'down' : view.status}`}
      aria-labelledby={headingId}
    >
      <h2 id={headingId}>{row.machine_name}</h2>
      {isDown ? (
        <DownBanner
          reason={row.down_reason}
          since={row.down_since}
          serverNowMs={estimateServerNow(row.server_time, fetchedAt, now)}
        />
      ) : (
        <StatusLine view={view} />
      )}
      <dl>
        <dt>{t('washroom.now')}</dt>
        <dd>
          {row.cycle_id ? (
            <>
              <WashGroupLabel
                name={row.wash_group_name}
                nameI18n={row.wash_group_name_i18n}
                colorHex={row.wash_group_color_hex}
              />
              <QueueBadges rewash={row.is_rewash} />
            </>
          ) : (
            <span>{t('washroom.empty')}</span>
          )}
        </dd>
        {row.cycle_id && row.formula_external_no && (
          <>
            <dt>{t('washroom.formula')}</dt>
            <dd>
              {t('washroom.formulaValue', {
                no: row.formula_external_no,
                minutes: row.cycle_minutes ?? '?',
              })}
            </dd>
          </>
        )}
        {!isDown && <dt>{t('washroom.next')}</dt>}
        {!isDown && (
          <dd>
            {/* Only a load pinned to THIS washer is shown here; unassigned work is listed once in
              the "Next in queue" panel (the board RPC repeats it on every free washer). */}
            {row.next_queue_item_id && row.next_is_assigned ? (
              <>
                <WashGroupLabel
                  name={row.next_wash_group_name}
                  nameI18n={row.next_wash_group_name_i18n}
                  colorHex={row.next_wash_group_color_hex}
                />
                <span>{qtyText(row.next_loads_remaining, row.next_qty, row.next_unit)}</span>
                <QueueBadges rush={row.next_is_rush} rewash={row.next_is_rewash} pinnedTo />
              </>
            ) : (
              <span>{t('washroom.nextFromQueue')}</span>
            )}
          </dd>
        )}
      </dl>
      <Link className="button-link" to={`/station/washer/${row.machine_id}`}>
        {t('washroom.openStation', { washer: row.machine_name })}
      </Link>
      {isDown && (
        <p>
          <Link to={`/control/machines?machine=${row.machine_id}`}>
            {t('machines.markUpNamed', { name: row.machine_name })}
          </Link>
        </p>
      )}
    </li>
  );
}

const NEXT_PANEL_LIMIT = 3;

/** The queue's next unassigned work, shown ONCE (any free washer takes the top item). */
function NextInQueue({ items }: { items: QueueRow[] }) {
  const { t } = useTranslation();
  const qtyText = useQtyText();
  const { shown, more } = nextUnassigned(items, NEXT_PANEL_LIMIT);
  return (
    <section className="card next-panel" aria-labelledby="next-in-queue">
      <h2 id="next-in-queue">{t('washroom.nextInQueue')}</h2>
      <p className="hint">{t('washroom.nextInQueueHint')}</p>
      {shown.length === 0 ? (
        <p>{t('washroom.noUnassigned')}</p>
      ) : (
        <ol className="next-list">
          {shown.map((item) => (
            <li key={item.id}>
              <WashGroupLabel
                name={item.wash_group_name}
                nameI18n={item.wash_group_name_i18n}
                colorHex={item.wash_group_color_hex}
              />
              <span>{qtyText(item.loads_remaining, item.qty, item.unit)}</span>
              <QueueBadges rush={item.is_rush} rewash={item.is_rewash} />
            </li>
          ))}
        </ol>
      )}
      {more > 0 && <p>{t('washroom.moreInQueue', { count: more })}</p>}
      <Link to="/control/queue">{t('washroom.seeQueue')}</Link>
    </section>
  );
}

export function WasherBoardPage() {
  const { t } = useTranslation();
  const now = useNow(1000);
  const areas = useAreas();
  const [areaId, setAreaId] = useState<string | null>(null);
  const washrooms = (areas.data ?? []).filter((a) => a.kind === 'washroom');
  const area = pickArea(washrooms, 'washroom', areaId);
  const board = useWashroomBoard(area?.id);
  useLiveRefetch(board.refetch, !!area);
  const queue = useQueue(area?.id);
  useLiveRefetch(queue.refetch, !!area);
  const taps = useTapSync();
  const machines = useMachineStatus(area?.plant_id);
  useLiveRefetch(machines.refetch, !!area);
  // Down machines that have no washer card here (dryers, ironers…, and washers turned off in setup).
  const boardIds = new Set((board.data ?? []).map((r) => r.machine_id));
  const otherDown = (machines.data ?? []).filter(
    (m) => m.status === 'down' && !boardIds.has(m.machine_id),
  );
  const machinesServerNow = estimateServerNow(
    machines.data?.[0]?.server_time,
    machines.dataUpdatedAt,
    now,
  );

  return (
    <main className="form-page">
      <p>
        <Link to="/control">{t('common.back')}</Link>
      </p>
      <h1>{t('washroom.boardTitle')}</h1>
      {washrooms.length > 1 && (
        <div className="field">
          <label htmlFor="area">{t('washroom.areaLabel')}</label>
          <select id="area" value={area?.id ?? ''} onChange={(e) => setAreaId(e.target.value)}>
            {washrooms.map((a) => (
              <option key={a.id} value={a.id}>
                {a.name}
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
      <p>
        <Link className="button-link secondary" to="/control/machines">
          {t('machines.linkLabel')}
        </Link>
      </p>
      {otherDown.length > 0 && (
        <section aria-labelledby="other-down">
          <h2 id="other-down">{t('machines.otherDown')}</h2>
          {otherDown.map((m) => (
            <DownBanner
              key={m.machine_id}
              name={`${m.machine_name} (${m.area_name})`}
              reason={m.reason}
              since={m.since}
              serverNowMs={machinesServerNow}
            />
          ))}
        </section>
      )}
      {queue.data && <NextInQueue items={queue.data} />}
      {queue.isError && !queue.data && <p className="error">{t(errorMessageKey(queue.error))}</p>}
      {board.data && board.data.length === 0 && <p>{t('washroom.noWashers')}</p>}
      {board.data && board.data.length > 0 && (
        <ul className="washer-list">
          {board.data.map((row) => (
            <WasherCard key={row.machine_id} row={row} fetchedAt={board.dataUpdatedAt} now={now} />
          ))}
        </ul>
      )}
    </main>
  );
}
