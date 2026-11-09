import { useEffect, useRef, useState, type FormEvent } from 'react';
import { useTranslation } from 'react-i18next';
import { groupOptionText } from '../customers/customerLookup';
import { useCustomerNameOf } from '../customers/useCustomerLookup';
import { useLocalNames } from '../../lib/seededNames';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { usernameFromEmail } from '../../lib/loginId';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow } from '../../lib/useNow';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { useMyRoles } from '../washroom/useMyRoles';
import { RewashForm } from './RewashForm';
import { DataAge } from '../washroom/DataAge';
import { useLocalizedName } from '../washroom/localizedName';
import { appErrorCode, errorMessageKey, unwrap } from '../washroom/rpcError';
import { useDirtyText } from '../dirtyWork/useDirtyText';
import { useDirtyWork } from '../dirtyWork/useDirtyWork';
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
import { QueueItem, WasherOption, type ItemChanges } from './QueueItem';
import { SortableQueueList } from './SortableQueueList';
import { applyMove, parseLoads, placeNumbers } from './queueOrder';
import '../../lib/forms.css';
import '../washroom/washroom.css';
import './queue.css';

// Work queue (PRD C1–C4). Owner decision 2026-11-04: only the OWNER changes the queue (add, reorder,
// assign a washer, RUSH, cancel); managers, leads and viewers see a read-only list. The server still
// lets managers edit until a separate migration tightens it; this screen only offers what the owner
// decided. Items are cancelled, never deleted.

/** Sends every editable field (update_queue_item is a full replacement). */
function updateArgs(item: QueueRow, changes: ItemChanges) {
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
  const customerOf = useCustomerNameOf();
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
                {groupOptionText(localized(g.name, g.name_i18n), customerOf(g.id))}
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
            required
          />
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

/** The viewer's own name as get_queue writes it (profile full name, else username), to hide it. */
function useMyName(userId: string, email: string | undefined, enabled: boolean) {
  return useQuery({
    queryKey: ['my-name', userId],
    enabled,
    staleTime: 10 * 60_000,
    queryFn: async (): Promise<string | null> => {
      const { data } = await supabase
        .from('profiles')
        .select('full_name')
        .eq('user_id', userId)
        .maybeSingle();
      return data?.full_name?.trim() || usernameFromEmail(email ?? '') || null;
    },
  });
}

type Toast = { kind: 'ok' | 'error'; text: string };

export function QueuePage() {
  const { t } = useTranslation();
  const names = useLocalNames();
  const localized = useLocalizedName();
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
  const myName = useMyName(session.user.id, session.user.email, isOwner);
  const machineStatus = useMachineStatus(area?.plant_id);
  const downIds = new Set(
    (machineStatus.data ?? []).filter((m) => m.status === 'down').map((m) => m.machine_id),
  );
  const queue = useQueue(area?.id);
  useLiveRefetch(queue.refetch, !!area);
  const washers = useWashers(isWashroom ? area?.id : undefined);
  const [toast, setToast] = useState<Toast | null>(null);
  const [showAdd, setShowAdd] = useState(false);
  const [showRewash, setShowRewash] = useState(false);
  const [filter, setFilter] = useState<'all' | 'rush' | 'rewash'>('all');
  const [openId, setOpenId] = useState<string | null>(null);
  const key = washroomKeys.queue(area?.id ?? '');

  // Success toasts fade after 5 s; errors stay until dismissed or replaced.
  useEffect(() => {
    if (toast?.kind !== 'ok') return;
    const id = window.setTimeout(() => setToast(null), 5000);
    return () => window.clearTimeout(id);
  }, [toast]);

  function onError(e: unknown) {
    if (appErrorCode(e) === 'QUEUE_VERSION_CONFLICT') {
      void queue.refetch();
      setToast({ kind: 'error', text: t('queue.changedRefreshed') });
    } else {
      setToast({ kind: 'error', text: t(errorMessageKey(e)) });
    }
  }
  function settle() {
    void qc.invalidateQueries({ queryKey: key });
    void qc.invalidateQueries({ queryKey: ['washroom-board'] });
  }

  const items = queue.data ?? [];
  const places = placeNumbers(items);
  const itemLabel = (id: string) => {
    const i = items.find((x) => x.id === id);
    return t('queue.itemLabel', {
      place: places.get(id) ?? 0,
      group: i ? localized(i.wash_group_name, i.wash_group_name_i18n) : '',
    });
  };

  // Optimistic reorder (frontend rules): the list moves at once (also right on drop, so the row
  // doesn't jump back), rolled back with a toast on error; a version conflict refetches.
  const move = useMutation({
    mutationFn: async (v: { item: QueueRow; afterId: string | null; previous?: QueueRow[] }) =>
      unwrap(
        await supabase.rpc('reorder_queue_item', {
          p_id: v.item.id,
          p_expected_version: v.item.version,
          ...(v.afterId ? { p_after_id: v.afterId } : {}),
        }),
      ),
    onSuccess: (row, v) => {
      // Keep the new version so the next move of this item doesn't conflict before the refetch.
      const saved = row as { version?: number; position?: number } | null;
      qc.setQueryData<QueueRow[]>(key, (list) =>
        list?.map((i) =>
          i.id === v.item.id && saved?.version !== undefined
            ? { ...i, version: saved.version, position: saved.position ?? i.position }
            : i,
        ),
      );
      const list = qc.getQueryData<QueueRow[]>(key) ?? [];
      const place = list.findIndex((i) => i.id === v.item.id) + 1;
      setToast({
        kind: 'ok',
        text: t('queue.moved', {
          item: localized(v.item.wash_group_name, v.item.wash_group_name_i18n),
          place,
        }),
      });
    },
    onError: (e, v) => {
      if (v.previous) qc.setQueryData(key, v.previous);
      onError(e);
    },
    onSettled: settle,
  });
  function doMove(item: QueueRow, afterId: string | null) {
    void qc.cancelQueries({ queryKey: key });
    const previous = qc.getQueryData<QueueRow[]>(key);
    if (previous) qc.setQueryData(key, applyMove(previous, item.id, afterId));
    setToast(null);
    move.mutate({ item, afterId, previous });
  }

  const update = useMutation({
    mutationFn: async (v: { item: QueueRow; changes: ItemChanges }) =>
      unwrap(await supabase.rpc('update_queue_item', updateArgs(v.item, v.changes))),
    onMutate: () => setToast(null),
    onSuccess: () => setToast({ kind: 'ok', text: t('queue.saved') }),
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
    onMutate: () => setToast(null),
    onSuccess: () => setToast({ kind: 'ok', text: t('queue.cancelled') }),
    onError,
    onSettled: settle,
  });

  const busy = move.isPending || update.isPending || cancel.isPending;
  const counts = {
    all: items.length,
    rush: items.filter((i) => i.is_rush).length,
    rewash: items.filter((i) => i.is_rewash).length,
  };
  // Empty filters are hidden (review 2026-11-09); fall back to All if the shown one empties.
  const shownFilter = filter !== 'all' && counts[filter] === 0 ? 'all' : filter;
  const filters = (['all', 'rush', 'rewash'] as const).filter((f) => f === 'all' || counts[f] > 0);
  const shown = items.filter(
    (i) => shownFilter === 'all' || (shownFilter === 'rush' ? i.is_rush : i.is_rewash),
  );
  // Drag: owner only, on the full list (a filtered list can't say where an item lands).
  const canDrag = isOwner && shownFilter === 'all' && items.length > 1;

  // Header numbers from the shared dirty-work selector (review §1/§3), so they match Home and
  // Estimates: our dirty work + each customer's drop-offs + rewash, whole loads, "N+" when unknown.
  const dirty = useDirtyWork(isWashroom ? area?.plant_id : undefined);
  const dirtyText = useDirtyText();
  const customerName = useCustomerNameOf();
  const d = isWashroom && dirty.data ? dirty.data : null;
  const summaryParts = [t('queue.summary', { count: items.length })];
  if (d) {
    summaryParts.push(
      t('dirty.queueOurs', { loads: dirtyText.loads(d.ours.loads, d.ours.unknown) }),
    );
    for (const c of d.customers)
      if (c.items > 0)
        summaryParts.push(
          t('dirty.queueCustomer', {
            name: customerName(dirty.customerGroupId.get(c.customerId)) ?? t('customers.generic'),
            loads: dirtyText.loads(c.loads, c.unknown),
          }),
        );
    if (d.rewash.items > 0)
      summaryParts.push(
        t('dirty.queueRewash', { loads: dirtyText.loads(d.rewash.loads, d.rewash.unknown) }),
      );
  }

  return (
    <main className="form-page q-page">
      <h1>{t('queue.title')}</h1>
      {items.length > 0 && <p className="q-summary mono">{summaryParts.join(' · ')}</p>}
      {/* Tablet landscape / desktop (owner 2026-11-09): controls on the left, the list on the right. */}
      <div className="q-layout">
        <div className="q-side">
          {(areas.data?.length ?? 0) > 1 && (
            <div className="field">
              <label htmlFor="q-area">{t('queue.areaLabel')}</label>
              <select
                id="q-area"
                value={area?.id ?? ''}
                onChange={(e) => setAreaId(e.target.value)}
              >
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
              onDone={(m) => setToast({ kind: 'ok', text: m })}
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
              onDone={(m) => setToast({ kind: 'ok', text: m })}
            />
          )}
        </div>
        <section className="q-main" aria-labelledby="q-list-title">
          <h2 id="q-list-title">{t('queue.listTitle')}</h2>
          {(areas.isPending || (area && queue.isPending)) && (
            <p role="status">{t('common.loading')}</p>
          )}
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
          {filters.length > 1 && (
            <div className="q-filters" role="group" aria-label={t('queue.filterLabel')}>
              {filters.map((f) => (
                <button
                  key={f}
                  type="button"
                  className="secondary"
                  aria-pressed={shownFilter === f}
                  onClick={() => setFilter(f)}
                >
                  {t(`queue.filter.${f}`, { count: counts[f] })}
                </button>
              ))}
            </div>
          )}
          {isOwner && items.length > 1 && (
            <p className="hint q-drag-help">
              {canDrag ? t('queue.dragHelp') : t('queue.dragNeedsAll')}
            </p>
          )}
          {items.length > 0 && (
            <SortableQueueList
              items={shown}
              enabled={canDrag}
              label={t('queue.listTitle')}
              itemLabel={itemLabel}
              placeOf={(id) => places.get(id) ?? 0}
              rowClass={(item) =>
                [
                  'queue-item',
                  item.is_rush ? 'rush' : '',
                  item.status === 'in_progress' ? 'started' : '',
                  openId === item.id ? 'open' : '',
                ]
                  .filter(Boolean)
                  .join(' ')
              }
              onDrop={doMove}
              renderItem={(item, handle) => (
                <QueueItem
                  item={item}
                  handle={handle}
                  items={items}
                  place={places.get(item.id) ?? 0}
                  open={openId === item.id}
                  onToggle={() => setOpenId((o) => (o === item.id ? null : item.id))}
                  canEdit={isOwner}
                  canMoveOff={isManager}
                  isWashroom={isWashroom}
                  washers={washers.data ?? []}
                  downIds={downIds}
                  busy={busy}
                  myName={myName.data ?? null}
                  onMove={(afterId) => doMove(item, afterId)}
                  onUpdate={(changes) => update.mutate({ item, changes })}
                  onCancel={() => cancel.mutate(item)}
                />
              )}
            />
          )}
        </section>
      </div>
      {/* Toast above the bottom nav, so a drag result or error is seen wherever the list is scrolled. */}
      <div className="q-toast-region">
        <div role="status" aria-live="polite">
          {toast?.kind === 'ok' && <p className="q-toast ok">{toast.text}</p>}
        </div>
        <div role="alert">
          {toast?.kind === 'error' && (
            <div className="q-toast error">
              <p>{toast.text}</p>
              <button type="button" className="secondary" onClick={() => setToast(null)}>
                {t('queue.dismiss')}
              </button>
            </div>
          )}
        </div>
      </div>
    </main>
  );
}
