import { useRef, useState, type FormEvent } from 'react';
import { useTranslation } from 'react-i18next';
import { useLocalNames } from '../../lib/seededNames';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow } from '../../lib/useNow';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { useMyRoles } from '../washroom/useMyRoles';
import { RewashForm } from './RewashForm';
import { DataAge } from '../washroom/DataAge';
import { IconDown, IconPin, IconRewash, IconRush, IconUp } from '../washroom/Icons';
import { GroupChip } from '../washroom/GroupChip';
import { useLocalizedName } from '../washroom/localizedName';
import { appErrorCode, errorMessageKey, unwrap } from '../washroom/rpcError';
import { useQtyText } from '../washroom/useQtyText';
import {
  pickArea,
  useAreas,
  useMachineStatus,
  useQueue,
  useWashers,
  useWashGroups,
  washroomKeys,
  type QueueRow,
  type WasherRow,
} from '../washroom/washroomData';
import {
  applyMove,
  canMove,
  moveAfterId,
  parseLoads,
  placeNumbers,
  type Direction,
} from './queueOrder';
import '../../lib/forms.css';
import '../washroom/washroom.css';
import './queue.css';

// Work queue (PRD C1–C4). Owner decision 2026-11-04: only the OWNER changes the queue (add, reorder,
// assign a washer, RUSH, cancel); managers, leads and viewers see a read-only list. The server still
// lets managers edit until a separate migration tightens it; this screen only offers what the owner
// decided. Items are cancelled, never deleted.

/** A washer <option>: a down washer says so in its text and can't be chosen. */
function WasherOption({ w, down }: { w: WasherRow; down: boolean }) {
  const { t } = useTranslation();
  const names = useLocalNames();
  return (
    <option value={w.id} disabled={down}>
      {down ? t('queue.washerDown', { name: names.machine(w.name) }) : names.machine(w.name)}
    </option>
  );
}

/** Sends every editable field (update_queue_item is a full replacement). */
function updateArgs(
  item: QueueRow,
  changes: { is_rush?: boolean; assigned_machine_id?: string | null },
) {
  const assigned =
    changes.assigned_machine_id !== undefined
      ? changes.assigned_machine_id
      : item.assigned_machine_id;
  return {
    p_id: item.id,
    p_expected_version: item.version,
    p_qty: item.qty,
    p_unit: item.unit,
    p_is_rush: changes.is_rush ?? item.is_rush,
    p_is_rewash: item.is_rewash,
    ...(item.note ? { p_note: item.note } : {}),
    ...(assigned ? { p_assigned_machine_id: assigned } : {}),
  };
}

function AddForm({
  areaId,
  plantId,
  isWashroom,
  washers,
  downIds,
  onDone,
}: {
  areaId: string;
  plantId: string;
  isWashroom: boolean;
  washers: WasherRow[];
  downIds: Set<string>;
  onDone: (message: string) => void;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const localized = useLocalizedName();
  const groups = useWashGroups(plantId);
  const [groupId, setGroupId] = useState('');
  const [loads, setLoads] = useState('1');
  const [rush, setRush] = useState(false);
  const [rewash, setRewash] = useState(false);
  const [washerId, setWasherId] = useState('');
  const [note, setNote] = useState('');
  const [fieldError, setFieldError] = useState<string | null>(null);
  // One client_id per item being added: a retry after a network error is the same item.
  const clientId = useRef<string | null>(null);

  const create = useMutation({
    mutationFn: async (qty: number) => {
      clientId.current ??= crypto.randomUUID();
      return unwrap(
        await supabase.rpc('create_queue_item', {
          p_area_id: areaId,
          p_qty: qty,
          p_unit: 'load',
          p_client_id: clientId.current,
          p_wash_group_id: groupId,
          p_is_rush: rush,
          p_is_rewash: isWashroom && rewash,
          ...(note.trim() ? { p_note: note.trim() } : {}),
          ...(washerId ? { p_assigned_machine_id: washerId } : {}),
        }),
      );
    },
    onSuccess: () => {
      const group = groups.data?.find((g) => g.id === groupId);
      clientId.current = null;
      setLoads('1');
      setRush(false);
      setRewash(false);
      setWasherId('');
      setNote('');
      onDone(t('queue.added', { group: group ? localized(group.name, group.name_i18n) : '' }));
    },
    onSettled: () => {
      void qc.invalidateQueries({ queryKey: washroomKeys.queue(areaId) });
      void qc.invalidateQueries({ queryKey: ['washroom-board'] });
    },
  });

  function onSubmit(e: FormEvent) {
    e.preventDefault();
    const qty = parseLoads(loads);
    if (!groupId) return setFieldError(t('queue.errors.chooseGroup'));
    if (qty === null) return setFieldError(t('queue.errors.loads'));
    setFieldError(null);
    create.mutate(qty);
  }

  return (
    <section className="card" aria-labelledby="add-title">
      <h2 id="add-title">{t('queue.addTitle')}</h2>
      <form onSubmit={onSubmit} noValidate>
        <div className="field">
          <label htmlFor="q-group">{t('queue.groupLabel')}</label>
          <select
            id="q-group"
            value={groupId}
            onChange={(e) => {
              setGroupId(e.target.value);
              clientId.current = null;
            }}
            required
          >
            <option value="">{t('queue.choose')}</option>
            {(groups.data ?? []).map((g) => (
              <option key={g.id} value={g.id}>
                {localized(g.name, g.name_i18n)}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label htmlFor="q-loads">{t('queue.loadsLabel')}</label>
          <input
            id="q-loads"
            inputMode="decimal"
            autoComplete="off"
            value={loads}
            onChange={(e) => {
              setLoads(e.target.value);
              clientId.current = null;
            }}
            aria-describedby="q-loads-hint"
            required
          />
          <p id="q-loads-hint" className="hint">
            {t('queue.loadsHint')}
          </p>
        </div>
        <div className="field check">
          <label>
            <input type="checkbox" checked={rush} onChange={(e) => setRush(e.target.checked)} />
            {t('queue.rushLabel')}
          </label>
        </div>
        {isWashroom && (
          <div className="field check">
            <label>
              <input
                type="checkbox"
                checked={rewash}
                onChange={(e) => setRewash(e.target.checked)}
              />
              {t('queue.rewashLabel')}
            </label>
          </div>
        )}
        {isWashroom && (
          <div className="field">
            <label htmlFor="q-washer">{t('queue.washerLabel')}</label>
            <select id="q-washer" value={washerId} onChange={(e) => setWasherId(e.target.value)}>
              <option value="">{t('queue.nextFreeWasher')}</option>
              {washers.map((w) => (
                <WasherOption key={w.id} w={w} down={downIds.has(w.id)} />
              ))}
            </select>
          </div>
        )}
        <div className="field">
          <label htmlFor="q-note">{t('queue.noteLabel')}</label>
          <input
            id="q-note"
            maxLength={140}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            autoComplete="off"
          />
        </div>
        <div role="alert">
          {fieldError && <p className="error">{fieldError}</p>}
          {create.isError && <p className="error">{t(errorMessageKey(create.error))}</p>}
        </div>
        <button type="submit" disabled={create.isPending}>
          {create.isPending ? t('queue.adding') : t('queue.add')}
        </button>
      </form>
    </section>
  );
}

function QueueItemCard({
  item,
  place,
  canEdit,
  canMoveOff,
  isWashroom,
  washers,
  downIds,
  canUp,
  canDown,
  busy,
  onMove,
  onUpdate,
  onCancel,
}: {
  item: QueueRow;
  place: number;
  canEdit: boolean;
  /** Manager exception 1: may move this load off its washer because that washer is down. */
  canMoveOff: boolean;
  isWashroom: boolean;
  washers: WasherRow[];
  downIds: Set<string>;
  canUp: boolean;
  canDown: boolean;
  busy: boolean;
  onMove: (dir: Direction) => void;
  onUpdate: (changes: { is_rush?: boolean; assigned_machine_id?: string | null }) => void;
  onCancel: () => void;
}) {
  const { t } = useTranslation();
  const names = useLocalNames();
  const qtyText = useQtyText();
  const localized = useLocalizedName();
  const [confirming, setConfirming] = useState(false);
  const groupName = localized(item.wash_group_name, item.wash_group_name_i18n);
  const washerSelectId = `washer-${item.id}`;
  const [moveTarget, setMoveTarget] = useState('');
  // Down = marked down, or turned off in setup (no longer an active washer).
  const assignedDown =
    !!item.assigned_machine_id &&
    (downIds.has(item.assigned_machine_id) ||
      !washers.some((w) => w.id === item.assigned_machine_id));

  return (
    <li className={item.is_rush ? 'queue-item rush' : 'queue-item'}>
      <div className="q-head">
        <span className="q-place mono">
          {t('queue.place', { n: String(place).padStart(2, '0') })}
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
          <span className="status-pill idle q-washer">
            <IconPin />{' '}
            {item.assigned_machine_name
              ? names.machine(item.assigned_machine_name)
              : t('queue.nextFreeWasher')}
          </span>
        </span>
      </div>
      <GroupChip
        name={item.wash_group_name}
        nameI18n={item.wash_group_name_i18n}
        colorHex={item.wash_group_color_hex}
      />
      {item.item_name && <p>{localized(item.item_name, item.item_name_i18n)}</p>}
      <p className="q-qty">
        {qtyText(item.loads_remaining, item.qty, item.unit)}
        {item.status === 'in_progress' &&
          ` · ${t('queue.inProgress', { count: item.loads_started })}`}
      </p>
      {item.note && <p className="hint">{t('queue.note', { note: item.note })}</p>}
      {assignedDown && (
        <p className="down-banner">
          <strong>
            {t('queue.assignedDown', { name: names.machine(item.assigned_machine_name) || '?' })}
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
          {isWashroom && (
            <div className="field">
              <label htmlFor={washerSelectId}>{t('queue.washerLabel')}</label>
              <select
                id={washerSelectId}
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
              disabled={!canUp || busy}
              onClick={() => onMove('up')}
            >
              <IconUp />
              {t('queue.moveUp')}
            </button>
            <button
              type="button"
              className="secondary"
              disabled={!canDown || busy}
              onClick={() => onMove('down')}
            >
              <IconDown />
              {t('queue.moveDown')}
            </button>
            <button
              type="button"
              className="secondary"
              disabled={busy}
              onClick={() => onUpdate({ is_rush: !item.is_rush })}
            >
              <IconRush />
              {item.is_rush ? t('queue.unmarkRush') : t('queue.markRush')}
            </button>
            {!confirming ? (
              <button
                type="button"
                className="danger"
                disabled={busy}
                onClick={() => setConfirming(true)}
              >
                {t('queue.cancelItem')}
              </button>
            ) : (
              <div role="group" aria-label={t('queue.confirmCancel', { group: groupName })}>
                <p>{t('queue.confirmCancel', { group: groupName })}</p>
                <div className="actions">
                  <button type="button" className="danger" disabled={busy} onClick={onCancel}>
                    {t('queue.confirmYes')}
                  </button>
                  <button type="button" className="secondary" onClick={() => setConfirming(false)}>
                    {t('queue.keep')}
                  </button>
                </div>
              </div>
            )}
          </div>
        </>
      )}
    </li>
  );
}

export function QueuePage() {
  const { t } = useTranslation();
  const names = useLocalNames();
  const session = useRequiredSession();
  const qc = useQueryClient();
  const now = useNow(1000);
  const areas = useAreas();
  const roles = useMyRoles(session.user.id);
  const [areaId, setAreaId] = useState<string | null>(null);
  const area = pickArea(areas.data, 'washroom', areaId);
  const isWashroom = area?.kind === 'washroom';
  const myRoles = roles.rolesFor(area?.plant_id);
  const isOwner = myRoles.has('owner');
  const isManager = !isOwner && myRoles.has('manager');
  const machineStatus = useMachineStatus(area?.plant_id);
  const downIds = new Set(
    (machineStatus.data ?? []).filter((m) => m.status === 'down').map((m) => m.machine_id),
  );
  const queue = useQueue(area?.id);
  useLiveRefetch(queue.refetch, !!area);
  const washers = useWashers(isWashroom ? area?.id : undefined);
  const [message, setMessage] = useState<string | null>(null);
  const [showAdd, setShowAdd] = useState(false);
  const [showRewash, setShowRewash] = useState(false);
  const [filter, setFilter] = useState<'all' | 'rush' | 'rewash'>('all');
  const [error, setError] = useState<string | null>(null);
  const key = washroomKeys.queue(area?.id ?? '');

  function onError(e: unknown) {
    if (appErrorCode(e) === 'QUEUE_VERSION_CONFLICT') {
      setError(t('errors.queueChanged'));
    } else {
      setError(t(errorMessageKey(e)));
    }
    setMessage(null);
  }
  function settle() {
    void qc.invalidateQueries({ queryKey: key });
    void qc.invalidateQueries({ queryKey: ['washroom-board'] });
  }

  // Optimistic reorder (frontend rules), rolled back on error.
  const move = useMutation({
    mutationFn: async (v: { item: QueueRow; afterId: string | null }) =>
      unwrap(
        await supabase.rpc('reorder_queue_item', {
          p_id: v.item.id,
          p_expected_version: v.item.version,
          ...(v.afterId ? { p_after_id: v.afterId } : {}),
        }),
      ),
    onMutate: async (v) => {
      await qc.cancelQueries({ queryKey: key });
      const previous = qc.getQueryData<QueueRow[]>(key);
      if (previous) qc.setQueryData(key, applyMove(previous, v.item.id, v.afterId));
      setError(null);
      return { previous };
    },
    onError: (e, _v, ctx) => {
      if (ctx?.previous) qc.setQueryData(key, ctx.previous);
      onError(e);
    },
    onSettled: settle,
  });

  const update = useMutation({
    mutationFn: async (v: {
      item: QueueRow;
      changes: { is_rush?: boolean; assigned_machine_id?: string | null };
    }) => unwrap(await supabase.rpc('update_queue_item', updateArgs(v.item, v.changes))),
    onMutate: () => setError(null),
    onSuccess: () => setMessage(t('queue.saved')),
    onError,
    onSettled: settle,
  });

  const cancel = useMutation({
    mutationFn: async (item: QueueRow) =>
      unwrap(
        await supabase.rpc('cancel_queue_item', {
          p_id: item.id,
          p_expected_version: item.version,
        }),
      ),
    onMutate: () => setError(null),
    onSuccess: () => setMessage(t('queue.cancelled')),
    onError,
    onSettled: settle,
  });

  const busy = move.isPending || update.isPending || cancel.isPending;
  const items = queue.data ?? [];
  const places = placeNumbers(items);
  // Loads still to wash: exact for loads, "≈" when any amount is converted from bins/baskets.
  const totalLoads = items.reduce((n, i) => n + (i.loads_remaining ?? 0), 0);
  const approxLoads = items.some((i) => i.unit !== 'load');

  return (
    <main className="form-page">
      <h1>{t('queue.title')}</h1>
      {items.length > 0 && (
        <p className="q-summary mono">
          {t('queue.summary', {
            count: items.length,
            loads: `${approxLoads ? '≈ ' : ''}${totalLoads}`,
          })}
        </p>
      )}
      {(areas.data?.length ?? 0) > 1 && (
        <div className="field">
          <label htmlFor="q-area">{t('queue.areaLabel')}</label>
          <select id="q-area" value={area?.id ?? ''} onChange={(e) => setAreaId(e.target.value)}>
            {(areas.data ?? []).map((a) => (
              <option key={a.id} value={a.id}>
                {names.area(a.name)}
              </option>
            ))}
          </select>
        </div>
      )}
      {!isOwner && area && roles.isSuccess && (
        <p className="notice">{isManager ? t('queue.managerNotice') : t('queue.readOnly')}</p>
      )}
      <DataAge
        updatedAt={queue.dataUpdatedAt}
        now={now}
        isFetching={queue.isFetching}
        isError={queue.isError && !!queue.data}
      />
      <div role="status" aria-live="polite">
        {message && <p>{message}</p>}
      </div>
      <div role="alert">{error && <p className="error">{error}</p>}</div>

      {isOwner && area && !showAdd && (
        <button type="button" className="q-add-button" onClick={() => setShowAdd(true)}>
          {t('queue.addOpen')}
        </button>
      )}
      {isOwner && area && showAdd && (
        <AddForm
          areaId={area.id}
          plantId={area.plant_id}
          isWashroom={isWashroom}
          washers={washers.data ?? []}
          downIds={downIds}
          onDone={(m) => {
            setMessage(m);
            setError(null);
          }}
        />
      )}

      {(isOwner || isManager) && area && isWashroom && !showRewash && (
        <button
          type="button"
          className="secondary q-add-button"
          onClick={() => setShowRewash(true)}
        >
          {t('rewash.open')}
        </button>
      )}
      {(isOwner || isManager) && area && isWashroom && showRewash && (
        <RewashForm
          areaId={area.id}
          plantId={area.plant_id}
          onDone={(m) => {
            setMessage(m);
            setError(null);
          }}
        />
      )}

      <h2>{t('queue.listTitle')}</h2>
      {(areas.isPending || (area && queue.isPending)) && <p role="status">{t('common.loading')}</p>}
      {areas.isSuccess && !area && <p>{t('queue.noArea')}</p>}
      {queue.isError && !queue.data && (
        <div role="alert">
          <p className="error">{t(errorMessageKey(queue.error))}</p>
          <button type="button" onClick={() => void queue.refetch()}>
            {t('common.tryAgain')}
          </button>
        </div>
      )}
      {queue.data && items.length === 0 && <p>{t('queue.empty')}</p>}
      {items.length > 0 && (
        <div className="q-filters" role="group" aria-label={t('queue.filterLabel')}>
          {(['all', 'rush', 'rewash'] as const).map((f) => (
            <button
              key={f}
              type="button"
              className="secondary"
              aria-pressed={filter === f}
              onClick={() => setFilter(f)}
            >
              {t(`queue.filter.${f}`, {
                count:
                  f === 'all'
                    ? items.length
                    : items.filter((i) => (f === 'rush' ? i.is_rush : i.is_rewash)).length,
              })}
            </button>
          ))}
        </div>
      )}
      {items.length > 0 && (
        <ol className="queue-list" aria-label={t('queue.listTitle')}>
          {items
            .filter((i) => filter === 'all' || (filter === 'rush' ? i.is_rush : i.is_rewash))
            .map((item) => (
              <QueueItemCard
                key={item.id}
                item={item}
                place={places.get(item.id) ?? 0}
                canEdit={isOwner}
                canMoveOff={isManager}
                isWashroom={isWashroom}
                washers={washers.data ?? []}
                downIds={downIds}
                canUp={canMove(items, item.id, 'up')}
                canDown={canMove(items, item.id, 'down')}
                busy={busy}
                onMove={(dir) => {
                  const afterId = moveAfterId(items, item.id, dir);
                  if (afterId !== undefined) move.mutate({ item, afterId });
                }}
                onUpdate={(changes) => update.mutate({ item, changes })}
                onCancel={() => cancel.mutate(item)}
              />
            ))}
        </ol>
      )}
    </main>
  );
}
