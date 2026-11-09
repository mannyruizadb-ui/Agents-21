import { useState, type FormEvent, type ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import { useLocalNames } from '../../lib/seededNames';
import { useCustomerNameOf } from '../customers/useCustomerLookup';
import { queueLoadsLeft } from '../dirtyWork/dirtyWork';
import { GroupChip } from '../washroom/GroupChip';
import {
  IconCustomer,
  IconDown,
  IconList,
  IconMachineDown,
  IconPin,
  IconRewash,
  IconRunning,
  IconRush,
  IconUp,
} from '../washroom/Icons';
import { useLocalizedName } from '../washroom/localizedName';
import { useQtyText } from '../washroom/useQtyText';
import type { QueueRow, WasherRow } from '../washroom/washroomData';
import { addedByToShow, moveAfterId, placeAfterId, placeRange, topAfterId } from './queueOrder';

// One queue item (review 2026-11-09 item 3): a one-line row (place, group, qty, tags) that opens
// its actions with one tap. Owner: washer, RUSH, Move to top / up / down / to position, Cancel.
// Manager: details, and "move off" when the item's washer is down. Others: details only.

export type ItemChanges = { is_rush?: boolean; assigned_machine_id?: string | null };

/** A washer <option>: a down washer says so in its text and can't be chosen. */
export function WasherOption({ w, down }: { w: WasherRow; down: boolean }) {
  const { t } = useTranslation();
  const names = useLocalNames();
  return (
    <option value={w.id} disabled={down}>
      {down ? t('queue.washerDown', { name: names.machine(w.name) }) : names.machine(w.name)}
    </option>
  );
}

/** The row: a button that opens the item's panel, or plain text when there is nothing behind it. */
function Toggle({
  open,
  panelId,
  onToggle,
  children,
}: {
  open: boolean;
  panelId: string;
  onToggle: (() => void) | null;
  children: ReactNode;
}) {
  if (!onToggle) return <div className="q-toggle q-static">{children}</div>;
  return (
    <button
      type="button"
      className="q-toggle"
      aria-expanded={open}
      aria-controls={panelId}
      onClick={onToggle}
    >
      {children}
    </button>
  );
}

export function QueueItem({
  item,
  items,
  handle,
  place,
  open,
  onToggle,
  canEdit,
  canMoveOff,
  isWashroom,
  washers,
  downIds,
  busy,
  myName,
  onMove,
  onUpdate,
  onCancel,
}: {
  item: QueueRow;
  /** The whole open queue in board order (for the move buttons). */
  items: readonly QueueRow[];
  /** The drag handle button (owner, full list), or null. */
  handle: ReactNode;
  place: number;
  open: boolean;
  onToggle: () => void;
  canEdit: boolean;
  /** Manager exception 1: may move this load off its washer because that washer is down. */
  canMoveOff: boolean;
  isWashroom: boolean;
  washers: WasherRow[];
  downIds: Set<string>;
  busy: boolean;
  myName: string | null;
  onMove: (afterId: string | null) => void;
  onUpdate: (changes: ItemChanges) => void;
  onCancel: () => void;
}) {
  const { t } = useTranslation();
  const names = useLocalNames();
  const qtyText = useQtyText();
  const localized = useLocalizedName();
  const customerOf = useCustomerNameOf();
  const [confirming, setConfirming] = useState(false);
  const [moveTarget, setMoveTarget] = useState('');
  const [placeText, setPlaceText] = useState('');
  const [placeError, setPlaceError] = useState<string | null>(null);
  const groupName = localized(item.wash_group_name, item.wash_group_name_i18n);
  const customer = customerOf(item.wash_group_id);
  const addedBy = addedByToShow(item.created_by_name, myName);
  const panelId = `q-panel-${item.id}`;
  // Down = marked down, or turned off in setup (no longer an active washer).
  const assignedDown =
    !!item.assigned_machine_id &&
    (downIds.has(item.assigned_machine_id) ||
      !washers.some((w) => w.id === item.assigned_machine_id));
  const range = placeRange(items, item.id);
  const upAfter = moveAfterId(items, item.id, 'up');
  const downAfter = moveAfterId(items, item.id, 'down');
  const topAfter = topAfterId(items, item.id);
  // Only a row with something behind it is a button (no empty panels for read-only viewers).
  const hasPanel =
    canEdit ||
    (canMoveOff && assignedDown) ||
    assignedDown ||
    !!item.item_name ||
    !!item.note ||
    !!addedBy;

  function onPlace(e: FormEvent) {
    e.preventDefault();
    if (!range) return;
    const n = Number(placeText.trim().replace(/^#/, ''));
    if (!Number.isInteger(n) || n < range.first || n > range.last) {
      setPlaceError(t('queue.movePositionInvalid', range));
      return;
    }
    setPlaceError(null);
    const after = placeAfterId(items, item.id, n);
    setPlaceText('');
    if (after !== undefined) onMove(after);
  }

  return (
    <>
      {/* Customer work (owner 2026-11-09): a big band at the top, above the group, never a small chip. */}
      {customer && (
        <div className="q-customer">
          <IconCustomer />
          <span>{customer}</span>
        </div>
      )}
      <div className="q-line">
        {handle}
        <Toggle open={open} panelId={panelId} onToggle={hasPanel ? onToggle : null}>
          <span className="q-place mono">
            {t('queue.place', { n: String(place).padStart(2, '0') })}
          </span>
          <span className="q-what">
            <GroupChip
              name={item.wash_group_name}
              nameI18n={item.wash_group_name_i18n}
              colorHex={item.wash_group_color_hex}
            />
            <span className="q-qty">{qtyText(queueLoadsLeft(item), item.qty, item.unit)}</span>
          </span>
          <span className="q-tags">
            {item.is_rush && (
              <span className="status-pill warn">
                <IconRush /> {t('queue.rush')}
              </span>
            )}
            {item.is_rewash && (
              <span className="status-pill info">
                <IconRewash /> {t('queue.rewash')}
              </span>
            )}
            {item.status === 'in_progress' && (
              <span className="status-pill ok">
                <IconRunning /> {t('queue.inProgress', { count: item.loads_started })}
              </span>
            )}
            {item.from_estimate && (
              <span className="status-pill idle">
                <IconList /> {t('queue.fromEstimate')}
              </span>
            )}
            {item.assigned_machine_name && (
              <span className={`status-pill q-washer ${assignedDown ? 'danger' : 'idle'}`}>
                {assignedDown ? <IconMachineDown /> : <IconPin />}{' '}
                {names.machine(item.assigned_machine_name)}
                {assignedDown && ` · ${t('queue.washerDownTag')}`}
              </span>
            )}
          </span>
          {hasPanel && (
            <span className="q-chevron" aria-hidden="true">
              {open ? <IconUp /> : <IconDown />}
            </span>
          )}
        </Toggle>
      </div>

      <div id={panelId} className="q-panel" hidden={!open || !hasPanel}>
        {open && hasPanel && (
          <>
            {item.item_name && <p>{localized(item.item_name, item.item_name_i18n)}</p>}
            {item.note && <p className="hint">{t('queue.note', { note: item.note })}</p>}
            {addedBy && <p className="hint">{t('names.addedBy', { name: addedBy })}</p>}
            {assignedDown && (
              <p className="down-banner">
                <strong>
                  {t('queue.assignedDown', {
                    name: names.machine(item.assigned_machine_name) || '?',
                  })}
                </strong>
              </p>
            )}

            {canMoveOff && assignedDown && (
              <div className="field">
                <label htmlFor={`move-${item.id}`}>{t('queue.moveOffLabel')}</label>
                <select
                  id={`move-${item.id}`}
                  value={moveTarget}
                  onChange={(e) => setMoveTarget(e.target.value)}
                >
                  <option value="">{t('queue.nextFreeWasher')}</option>
                  {washers
                    .filter((w) => w.id !== item.assigned_machine_id)
                    .map((w) => (
                      <WasherOption key={w.id} w={w} down={downIds.has(w.id)} />
                    ))}
                </select>
                <div className="actions">
                  <button
                    type="button"
                    disabled={busy}
                    onClick={() => onUpdate({ assigned_machine_id: moveTarget || null })}
                  >
                    {t('queue.moveOff')}
                  </button>
                </div>
              </div>
            )}

            {canEdit && (
              <>
                <div className="actions q-move">
                  <button
                    type="button"
                    className="secondary"
                    disabled={topAfter === undefined || busy}
                    onClick={() => onMove(null)}
                  >
                    <IconUp />
                    {t('queue.moveTop')}
                  </button>
                  <button
                    type="button"
                    className="secondary"
                    disabled={upAfter === undefined || busy}
                    onClick={() => upAfter !== undefined && onMove(upAfter)}
                  >
                    <IconUp />
                    {t('queue.moveUp')}
                  </button>
                  <button
                    type="button"
                    className="secondary"
                    disabled={downAfter === undefined || busy}
                    onClick={() => downAfter !== undefined && onMove(downAfter)}
                  >
                    <IconDown />
                    {t('queue.moveDown')}
                  </button>
                </div>
                {range && range.last > range.first && (
                  <form className="q-position" onSubmit={onPlace} noValidate>
                    <div className="field">
                      <label htmlFor={`pos-${item.id}`}>{t('queue.movePositionLabel')}</label>
                      <div className="q-position-row">
                        <input
                          id={`pos-${item.id}`}
                          inputMode="numeric"
                          autoComplete="off"
                          aria-describedby={`pos-hint-${item.id}`}
                          value={placeText}
                          onChange={(e) => setPlaceText(e.target.value)}
                        />
                        <button type="submit" className="secondary" disabled={busy}>
                          {t('queue.movePositionGo')}
                        </button>
                      </div>
                      <p id={`pos-hint-${item.id}`} className="hint">
                        {t('queue.movePositionHint', range)}
                        {item.is_rush ? '' : ` · ${t('queue.rushStaysTop')}`}
                      </p>
                      <div role="alert">{placeError && <p className="error">{placeError}</p>}</div>
                    </div>
                  </form>
                )}
                {isWashroom && (
                  <div className="field">
                    <label htmlFor={`washer-${item.id}`}>{t('queue.washerLabel')}</label>
                    <select
                      id={`washer-${item.id}`}
                      value={item.assigned_machine_id ?? ''}
                      disabled={busy}
                      onChange={(e) => onUpdate({ assigned_machine_id: e.target.value || null })}
                    >
                      <option value="">{t('queue.nextFreeWasher')}</option>
                      {/* Keep a washer that was turned off visible while the item is still on it. */}
                      {item.assigned_machine_id &&
                        !washers.some((w) => w.id === item.assigned_machine_id) && (
                          <option value={item.assigned_machine_id}>
                            {names.machine(item.assigned_machine_name) || '?'}
                          </option>
                        )}
                      {washers.map((w) => (
                        <WasherOption key={w.id} w={w} down={downIds.has(w.id)} />
                      ))}
                    </select>
                  </div>
                )}
                <div className="actions">
                  <button
                    type="button"
                    className="secondary"
                    disabled={busy}
                    onClick={() => onUpdate({ is_rush: !item.is_rush })}
                  >
                    <IconRush />
                    {item.is_rush ? t('queue.unmarkRush') : t('queue.markRush')}
                  </button>
                  {!confirming && (
                    <button
                      type="button"
                      className="danger"
                      disabled={busy}
                      onClick={() => setConfirming(true)}
                    >
                      {t('queue.cancelItem')}
                    </button>
                  )}
                </div>
                {confirming && (
                  <div role="group" aria-label={t('queue.confirmCancel', { group: groupName })}>
                    <p>{t('queue.confirmCancel', { group: groupName })}</p>
                    <div className="actions">
                      <button type="button" className="danger" disabled={busy} onClick={onCancel}>
                        {t('queue.confirmYes')}
                      </button>
                      <button
                        type="button"
                        className="secondary"
                        onClick={() => setConfirming(false)}
                      >
                        {t('queue.keep')}
                      </button>
                    </div>
                  </div>
                )}
              </>
            )}
          </>
        )}
      </div>
    </>
  );
}
