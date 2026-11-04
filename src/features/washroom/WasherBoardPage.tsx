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
import { formatCountdown, minutesLeftRoundedUp, washerNow, type WasherNow } from './washerTime';
import { pickArea, useAreas, useWashroomBoard, type WasherBoardRow } from './washroomData';
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
  return (
    <li className={`washer-card status-${view.status}`} aria-labelledby={headingId}>
      <h2 id={headingId}>{row.machine_name}</h2>
      <StatusLine view={view} />
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
        <dt>{t('washroom.next')}</dt>
        <dd>
          {row.next_queue_item_id ? (
            <>
              <WashGroupLabel
                name={row.next_wash_group_name}
                nameI18n={row.next_wash_group_name_i18n}
                colorHex={row.next_wash_group_color_hex}
              />
              <span>{qtyText(row.next_loads_remaining, row.next_qty, row.next_unit)}</span>
              <QueueBadges
                rush={row.next_is_rush}
                rewash={row.next_is_rewash}
                pinnedTo={row.next_is_assigned ? true : null}
              />
            </>
          ) : (
            <span>{t('washroom.nothingQueued')}</span>
          )}
        </dd>
      </dl>
      <Link className="button-link" to={`/station/washer/${row.machine_id}`}>
        {t('washroom.openStation', { washer: row.machine_name })}
      </Link>
    </li>
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
  const taps = useTapSync();

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
