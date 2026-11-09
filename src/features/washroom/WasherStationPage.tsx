import { useEffect, useRef, useState } from 'react';
import { Link, useParams } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useLocalNames } from '../../lib/seededNames';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow, useOnline } from '../../lib/useNow';
import { DataAge } from './DataAge';
import { IconIdle, IconOffline, IconReady, IconRunning, IconStart, IconWarning } from './Icons';
import { QueueBadges } from './QueueBadges';
import { WashGroupLabel } from './WashGroupLabel';
import { useLocalizedName } from './localizedName';
import { needsOffQueueReason, type OffQueueReason } from './offQueue';
import { OffQueueReasonPicker } from './OffQueueReasonPicker';
import { errorMessageKey, tapRejectedKey } from './rpcError';
import { MANAGER_UNDO_WINDOW_MS, UNDO_WINDOW_MS, useTapSync } from './useTapSync';
import { useMyRoles } from './useMyRoles';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { useQtyText } from './useQtyText';
import { estimateServerNow, formatCountdown, minutesLeftRoundedUp, washerNow } from './washerTime';
import { DownBanner } from './DownBanner';
import { TapAlarmBanner } from './TapAlarmBanner';
import { useMachine, useWashGroups, useWashroomBoard, type WashGroupRow } from './washroomData';
import './washroom.css';

// Washer station (PRD F1/D1, owner plan 2026-11-04): a tablet mounted at ONE washer opens
// /station/washer/:machineId in kiosk mode. NOW + countdown, NEXT, one big green START, "other wash
// group", UNDO for a short window. Taps carry no name or PIN (owner 2026-11-02). Every tap is saved
// on the device before it is sent and retried until the server records it.

/** START is locked briefly after a tap so a double tap doesn't start two loads. */
const START_LOCK_MS = 4000;

interface LastTap {
  clientId: string;
  at: number;
  groupName: string;
}

function useWakeLock() {
  useEffect(() => {
    let lock: WakeLockSentinel | null = null;
    let cancelled = false;
    const request = async () => {
      try {
        if (document.visibilityState === 'visible' && 'wakeLock' in navigator) {
          lock = await navigator.wakeLock.request('screen');
          if (cancelled) void lock.release();
        }
      } catch {
        // Not supported or refused (low battery): the screen may sleep; nothing else to do.
      }
    };
    void request();
    const onVisible = () => void request();
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      cancelled = true;
      document.removeEventListener('visibilitychange', onVisible);
      void lock?.release().catch(() => undefined);
    };
  }, []);
}

export function WasherStationPage() {
  const names = useLocalNames();
  const { machineId } = useParams();
  const { t } = useTranslation();
  const localized = useLocalizedName();
  const qtyText = useQtyText();
  const now = useNow(1000);
  const online = useOnline();
  useWakeLock();

  const machine = useMachine(machineId);
  const areaId = machine.data?.area_id;
  const board = useWashroomBoard(areaId);
  useLiveRefetch(board.refetch, !!areaId);
  const groups = useWashGroups(machine.data?.plant_id);
  const taps = useTapSync();

  const [override, setOverride] = useState<WashGroupRow | null>(null);
  const [pickerOpen, setPickerOpen] = useState(false);
  const [lastTap, setLastTap] = useState<LastTap | null>(null);
  const [undoState, setUndoState] = useState<'idle' | 'busy' | 'done' | 'error'>('idle');
  const [undoError, setUndoError] = useState<unknown>(null);
  const startRef = useRef<HTMLButtonElement>(null);
  // Owner 2026-11-06: START on a washer that is still running asks first (the server insists too).
  const [confirmingRunning, setConfirmingRunning] = useState(false);
  // Owner 2026-11-09: a hand-picked group that is not the queue's next asks "why?" first (one tap).
  const [askingReason, setAskingReason] = useState(false);
  const [chosenReason, setChosenReason] = useState<OffQueueReason | null>(null);
  // A refused tap (queue changed while it waited) whose reason is being picked.
  const [reasonFor, setReasonFor] = useState<string | null>(null);
  const session = useRequiredSession();
  const roles = useMyRoles(session.user.id).rolesFor(machine.data?.plant_id);
  const undoWindowMs =
    roles.has('owner') || roles.has('manager') ? MANAGER_UNDO_WINDOW_MS : UNDO_WINDOW_MS;

  const row = board.data?.find((r) => r.machine_id === machineId);
  const isDown = !!row?.is_down;
  const view = row
    ? washerNow(row.status, row.expected_end_at, row.server_time, board.dataUpdatedAt, now)
    : null;

  // What START will run: the chosen group, else what the queue says is next for this washer.
  const startGroupName = override
    ? localized(override.name, override.name_i18n)
    : row?.next_queue_item_id
      ? localized(row.next_wash_group_name, row.next_wash_group_name_i18n)
      : null;

  const offQueue = needsOffQueueReason(
    override?.id,
    row?.next_queue_item_id,
    row?.next_wash_group_id,
  );
  const queueNextName = row?.next_queue_item_id
    ? localized(row.next_wash_group_name, row.next_wash_group_name_i18n)
    : null;

  const locked = lastTap !== null && now - lastTap.at < START_LOCK_MS;
  const undoLeftMs = lastTap ? undoWindowMs - (now - lastTap.at) : 0;
  const lastPending = lastTap ? taps.pending.some((p) => p.clientId === lastTap.clientId) : false;
  const lastSent = lastTap ? taps.sent[lastTap.clientId] : undefined;
  // Too-late taps are shown by the loud TapAlarmBanner instead (owner 2026-11-05).
  const refused = taps.rejected.filter((r) => r.errorCode !== 'OUT_OF_RANGE_TIMESTAMP');
  const lastRejected = lastTap ? refused.find((r) => r.clientId === lastTap.clientId) : undefined;
  const otherRejected = refused.filter(
    (r) => r.machineId === machineId && r.clientId !== lastTap?.clientId,
  );
  const showUndo =
    lastTap !== null && undoLeftMs > 0 && undoState !== 'done' && (lastPending || !!lastSent);

  /** Order (server order too): the off-queue reason first, then "still running — start anyway?". */
  function onStart(confirmRunning = false, pickedReason: OffQueueReason | null = null) {
    if (!machineId || !startGroupName || locked) return;
    const reason = offQueue ? (pickedReason ?? chosenReason) : null;
    if (offQueue && !reason) {
      setAskingReason(true);
      return;
    }
    setAskingReason(false);
    if (view?.status === 'running' && !confirmRunning) {
      setChosenReason(reason);
      setConfirmingRunning(true);
      return;
    }
    setConfirmingRunning(false);
    setChosenReason(null);
    // Server clock − device clock, so the stored tap time is in server time (see useTapSync.tap).
    const offset = row ? Date.parse(row.server_time) - board.dataUpdatedAt : 0;
    const clientId = taps.tap(
      machineId,
      override?.id ?? null,
      Number.isFinite(offset) ? offset : 0,
      confirmRunning,
      reason,
    );
    setLastTap({ clientId, at: now, groupName: startGroupName });
    setUndoState('idle');
    setUndoError(null);
    setOverride(null);
    setPickerOpen(false);
  }

  async function onUndo() {
    if (!lastTap) return;
    setUndoState('busy');
    try {
      await taps.undo(lastTap.clientId);
      setUndoState('done');
      startRef.current?.focus();
    } catch (e) {
      setUndoError(e);
      setUndoState('error');
    }
  }

  if (machine.isPending) {
    return (
      <main className="station">
        <p role="status">{t('common.loading')}</p>
      </main>
    );
  }
  if (machine.isError || !machine.data || machine.data.kind !== 'washer') {
    return (
      <main className="station">
        <h1>{t('station.title')}</h1>
        <p className="station-message bad" role="alert">
          <IconWarning />
          {machine.isError ? t(errorMessageKey(machine.error)) : t('station.notAWasher')}
        </p>
        <Link to="/control/washers">{t('station.toBoard')}</Link>
      </main>
    );
  }

  return (
    <main className="station">
      <header className="station-header">
        <h1>{names.machine(machine.data.name)}</h1>
        <DataAge
          updatedAt={board.dataUpdatedAt}
          now={now}
          isFetching={board.isFetching}
          isError={board.isError && !!board.data}
        />
      </header>
      <TapAlarmBanner variant="dark" />

      {isDown && row && (
        <div role="alert">
          <DownBanner
            reasonCode={row.down_reason_code}
            reasonLabelI18n={row.down_reason_label_i18n}
            reason={row.down_reason}
            since={row.down_since}
            serverNowMs={estimateServerNow(row.server_time, board.dataUpdatedAt, now)}
          />
          <p className="meta">{t('station.downNoStart')}</p>
          <p>
            <Link to={`/control/machines?machine=${machine.data.id}`}>
              {t('machines.markUpNamed', { name: names.machine(machine.data.name) })}
            </Link>
          </p>
        </div>
      )}
      {!machine.data.active && (
        <p className="station-message bad" role="alert">
          <IconWarning />
          {t('station.inactive')}
        </p>
      )}
      {!online && (
        <p className="station-message warn">
          <IconOffline />
          {t('station.offline')}
        </p>
      )}
      {board.isError && !board.data && (
        <div className="station-message bad" role="alert">
          <IconWarning />
          <p>{t(errorMessageKey(board.error))}</p>
          <button type="button" onClick={() => void board.refetch()}>
            {t('common.tryAgain')}
          </button>
        </div>
      )}

      {/* NOW and NEXT: stacked on a phone, side by side on a tablet (owner 2026-11-09). */}
      <div className="station-panels">
        <section
          className={`station-panel station-now${view?.status === 'ready' ? ' station-ready' : ''}`}
          aria-labelledby="now-title"
        >
          <h2 id="now-title">{t('washroom.now')}</h2>
          {row?.cycle_id ? (
            <>
              <WashGroupLabel
                name={row.wash_group_name}
                nameI18n={row.wash_group_name_i18n}
                colorHex={row.wash_group_color_hex}
                washGroupId={row.wash_group_id}
              />
              {row.is_rewash && (
                <p className="meta">
                  <QueueBadges rewash />
                </p>
              )}
            </>
          ) : (
            <p className="status-line">
              <IconIdle />
              {t('washroom.empty')}
            </p>
          )}
          {view?.status === 'running' && (
            <>
              <p className="status-line">
                <IconRunning />
                {t('washroom.status.running')}
              </p>
              {view.left !== null && (
                <p className="countdown">
                  <span aria-hidden="true">{formatCountdown(view.left)}</span>
                  <span className="visually-hidden">
                    {t('washroom.minutesLeft', { count: minutesLeftRoundedUp(view.left) })}
                  </span>
                </p>
              )}
            </>
          )}
          {view?.status === 'ready' && (
            <p className="status-line">
              <IconReady />
              {t('washroom.status.ready')}
              {view.readyMinutes !== null &&
                ` · ${t('washroom.waitingMinutes', { count: view.readyMinutes })}`}
            </p>
          )}
          {view?.status === 'unknown' && (
            <p className="status-line">
              <IconWarning />
              {t('washroom.status.unknown')}
            </p>
          )}
        </section>

        {/* NEXT (none while down: the board gives a down washer no NEXT) */}
        {!isDown && (
          <section className="station-panel station-next" aria-labelledby="next-title">
            <h2 id="next-title">{t('washroom.next')}</h2>
            {row?.next_queue_item_id ? (
              <>
                <WashGroupLabel
                  name={row.next_wash_group_name}
                  nameI18n={row.next_wash_group_name_i18n}
                  colorHex={row.next_wash_group_color_hex}
                  washGroupId={row.next_wash_group_id}
                />
                <p className="meta">
                  <span>{qtyText(row.next_loads_remaining, row.next_qty, row.next_unit)}</span>
                  <QueueBadges
                    rush={row.next_is_rush}
                    rewash={row.next_is_rewash}
                    pinnedTo={row.next_is_assigned ? true : null}
                  />
                </p>
              </>
            ) : (
              <p className="status-line">{board.data ? t('washroom.nothingQueued') : '…'}</p>
            )}
          </section>
        )}
      </div>

      {/* Status of the last tap, and taps that are waiting or were refused. */}
      <div role="status" aria-live="polite">
        {lastTap && undoState === 'done' && (
          <p className="station-message ok">
            <IconReady />
            {t('station.undone', { group: lastTap.groupName })}
          </p>
        )}
        {lastTap && undoState !== 'done' && lastSent && (
          <p className="station-message ok">
            <IconReady />
            {t('station.started', {
              group: lastTap.groupName,
              washer: names.machine(machine.data.name),
            })}
          </p>
        )}
        {lastTap && undoState !== 'done' && lastPending && (
          <p className="station-message warn">
            <IconOffline />
            {t('station.savedNotSent', { group: lastTap.groupName })}
          </p>
        )}
        {taps.pending.length > 0 && !lastPending && (
          <p className="station-message warn">
            <IconOffline />
            {t('station.pendingCount', { count: taps.pending.length })}
          </p>
        )}
        {!taps.persistent && (
          <p className="station-message warn">
            <IconWarning />
            {t('station.noStorage')}
          </p>
        )}
      </div>
      {[...(lastRejected ? [lastRejected] : []), ...otherRejected].map((r) => (
        <div key={r.clientId} className="station-message bad" role="alert">
          <IconWarning />
          <p>
            {t('station.rejected', {
              time: new Date(r.tappedAt).toLocaleTimeString(undefined, {
                hour: 'numeric',
                minute: '2-digit',
              }),
            })}{' '}
            {t(tapRejectedKey(r.errorCode))}
          </p>
          {r.errorCode === 'WASHER_RUNNING' && (
            <button type="button" onClick={() => taps.resend(r, { confirmRunning: true })}>
              {t('station.startAnyway')}
            </button>
          )}
          {r.errorCode === 'OFF_QUEUE_REASON_REQUIRED' && reasonFor !== r.clientId && (
            <button type="button" onClick={() => setReasonFor(r.clientId)}>
              {t('station.pickReason')}
            </button>
          )}
          {reasonFor === r.clientId ? (
            <OffQueueReasonPicker
              question={t('station.offQueueQGeneric')}
              onPick={(reason) => {
                setReasonFor(null);
                taps.resend(r, { offQueueReason: reason });
              }}
              onCancel={() => setReasonFor(null)}
            />
          ) : (
            <button type="button" onClick={() => taps.dismiss(r.clientId)}>
              {t('station.dismiss')}
            </button>
          )}
        </div>
      ))}

      {showUndo && (
        <div>
          <button
            type="button"
            className="undo-button"
            onClick={() => void onUndo()}
            disabled={undoState === 'busy'}
          >
            {t('station.undoCountdown', { count: Math.max(0, Math.ceil(undoLeftMs / 1000)) })}
          </button>

          {undoState === 'error' && (
            <p className="station-message bad" role="alert">
              <IconWarning />
              {t(errorMessageKey(undoError))}
            </p>
          )}
        </div>
      )}

      {/* START, hidden while the washer is down (the server refuses with MACHINE_DOWN anyway). */}
      {!isDown && (
        <>
          <button
            ref={startRef}
            type="button"
            className="start-button"
            onClick={() => onStart()}
            disabled={
              !startGroupName || locked || !machine.data.active || confirmingRunning || askingReason
            }
            aria-describedby="start-what"
          >
            <IconStart size="1em" />
            <span>{locked ? t('station.startedShort') : t('station.start')}</span>
          </button>
          {askingReason && startGroupName && (
            <OffQueueReasonPicker
              question={
                queueNextName
                  ? t('station.offQueueQ', { next: queueNextName, chosen: startGroupName })
                  : t('station.offQueueQGeneric')
              }
              onPick={(reason) => onStart(false, reason)}
              onCancel={() => setAskingReason(false)}
            />
          )}
          {confirmingRunning && (
            <div
              className="confirm-box station-message warn"
              role="alertdialog"
              aria-labelledby="running-q"
            >
              <IconWarning />
              <p id="running-q">
                <strong>
                  {row?.expected_end_at
                    ? t('station.stillRunningUntil', {
                        washer: names.machine(machine.data.name),
                        time: new Date(row.expected_end_at).toLocaleTimeString(undefined, {
                          hour: 'numeric',
                          minute: '2-digit',
                        }),
                      })
                    : t('station.stillRunning', { washer: names.machine(machine.data.name) })}
                </strong>{' '}
                {t('station.startAnotherQ')}
              </p>
              <div className="row">
                <button
                  type="button"
                  className="start-button"
                  onClick={() => onStart(true, chosenReason)}
                >
                  {t('station.startAnyway')}
                </button>
                <button
                  type="button"
                  onClick={() => {
                    setConfirmingRunning(false);
                    setChosenReason(null);
                  }}
                >
                  {t('common.cancel')}
                </button>
              </div>
            </div>
          )}
          <p id="start-what" className="meta">
            {startGroupName
              ? override
                ? t('station.willStartOther', { group: startGroupName })
                : t('station.willStart', { group: startGroupName })
              : t('station.chooseGroup')}
          </p>

          <div className="row">
            <button
              type="button"
              aria-expanded={pickerOpen}
              aria-controls="group-picker"
              onClick={() => setPickerOpen((o) => !o)}
            >
              {t('station.otherGroup')}
            </button>
            {override && (
              <button
                type="button"
                onClick={() => {
                  setOverride(null);
                  setAskingReason(false);
                  setChosenReason(null);
                }}
              >
                {t('station.useQueue')}
              </button>
            )}
          </div>
          {pickerOpen && (
            <section id="group-picker" aria-label={t('station.otherGroup')}>
              {groups.isError && (
                <p className="station-message bad">{t(errorMessageKey(groups.error))}</p>
              )}
              <ul className="group-picker">
                {(groups.data ?? []).map((g) => (
                  <li key={g.id}>
                    <button
                      type="button"
                      aria-pressed={override?.id === g.id}
                      onClick={() => {
                        setOverride(g);
                        setAskingReason(false);
                        setChosenReason(null);
                        setPickerOpen(false);
                        startRef.current?.focus();
                      }}
                    >
                      <WashGroupLabel
                        name={g.name}
                        nameI18n={g.name_i18n}
                        colorHex={g.color_hex}
                        washGroupId={g.id}
                      />
                    </button>
                  </li>
                ))}
              </ul>
            </section>
          )}
        </>
      )}

      <p>
        <Link to={`/control/machines?machine=${machine.data.id}`}>{t('machines.linkLabel')}</Link>
      </p>
      <p>
        <Link to="/control/washers">{t('station.toBoard')}</Link>
      </p>
    </main>
  );
}
