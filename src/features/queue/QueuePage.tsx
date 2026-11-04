import { useRef, useState, type FormEvent } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow } from '../../lib/useNow';
import type { Database } from '../../types/database';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { useOwnerPlants } from '../admin/useOwnerPlants';
import { DataAge } from '../washroom/DataAge';
import { IconDown, IconRush, IconUp } from '../washroom/Icons';
import { QueueBadges } from '../washroom/QueueBadges';
import { WashGroupLabel } from '../washroom/WashGroupLabel';
import { useLocalizedName } from '../washroom/localizedName';
import { appErrorCode, errorMessageKey, unwrap } from '../washroom/rpcError';
import { useQtyText } from '../washroom/useQtyText';
import {
  LIVE_REFETCH_MS,
  pickArea,
  useAreas,
  useWashers,
  useWashGroups,
  washroomKeys,
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

// Work queue (PRD C1–C4). Owner decision 2026-11-04: only the OWNER changes the queue (add, reorder,
// assign a washer, RUSH, cancel); managers, leads and viewers see a read-only list. The server still
// lets managers edit until a separate migration tightens it; this screen only offers what the owner
// decided. Items are cancelled, never deleted.

type QueueRow = Database['public']['Functions']['get_queue']['Returns'][number];

function useQueue(areaId: string | undefined) {
  return useQuery({
    queryKey: washroomKeys.queue(areaId ?? ''),
    enabled: !!areaId,
    queryFn: async (): Promise<QueueRow[]> =>
      unwrap(await supabase.rpc('get_queue', { p_area_id: areaId ?? '' })) ?? [],
    refetchInterval: LIVE_REFETCH_MS,
  });
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
  onDone,
}: {
  areaId: string;
  plantId: string;
  isWashroom: boolean;
  washers: WasherRow[];
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
                <option key={w.id} value={w.id}>
                  {w.name}
                </option>
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
  isWashroom,
  washers,
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
  isWashroom: boolean;
  washers: WasherRow[];
  canUp: boolean;
  canDown: boolean;
  busy: boolean;
  onMove: (dir: Direction) => void;
  onUpdate: (changes: { is_rush?: boolean; assigned_machine_id?: string | null }) => void;
  onCancel: () => void;
}) {
  const { t } = useTranslation();
  const qtyText = useQtyText();
  const localized = useLocalizedName();
  const [confirming, setConfirming] = useState(false);
  const groupName = localized(item.wash_group_name, item.wash_group_name_i18n);
  const washerSelectId = `washer-${item.id}`;

  return (
    <li className={item.is_rush ? 'queue-item rush' : 'queue-item'}>
      <p className="queue-item-head">
        <span className="queue-item-pos">{t('queue.place', { n: place })}</span>
        <WashGroupLabel
          name={item.wash_group_name}
          nameI18n={item.wash_group_name_i18n}
          colorHex={item.wash_group_color_hex}
        />
        <QueueBadges
          rush={item.is_rush}
          rewash={item.is_rewash}
          pinnedTo={!canEdit ? item.assigned_machine_name : null}
        />
      </p>
      {item.item_name && <p>{localized(item.item_name, item.item_name_i18n)}</p>}
      <p>
        {qtyText(item.loads_remaining, item.qty, item.unit)}
        {item.status === 'in_progress' &&
          ` · ${t('queue.inProgress', { started: item.loads_started })}`}
      </p>
      {item.note && <p className="hint">{t('queue.note', { note: item.note })}</p>}

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
                      {item.assigned_machine_name ?? '?'}
                    </option>
                  )}
                {washers.map((w) => (
                  <option key={w.id} value={w.id}>
                    {w.name}
                  </option>
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
  const session = useRequiredSession();
  const qc = useQueryClient();
  const now = useNow(1000);
  const areas = useAreas();
  const ownerPlants = useOwnerPlants(session.user.id);
  const [areaId, setAreaId] = useState<string | null>(null);
  const area = pickArea(areas.data, 'washroom', areaId);
  const isWashroom = area?.kind === 'washroom';
  const isOwner = !!area && (ownerPlants.data ?? []).some((p) => p.id === area.plant_id);
  const queue = useQueue(area?.id);
  useLiveRefetch(queue.refetch, !!area);
  const washers = useWashers(isWashroom ? area?.id : undefined);
  const [message, setMessage] = useState<string | null>(null);
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

  return (
    <main className="form-page">
      <p>
        <Link to="/control">{t('common.back')}</Link>
      </p>
      <h1>{t('queue.title')}</h1>
      {(areas.data?.length ?? 0) > 1 && (
        <div className="field">
          <label htmlFor="q-area">{t('queue.areaLabel')}</label>
          <select id="q-area" value={area?.id ?? ''} onChange={(e) => setAreaId(e.target.value)}>
            {(areas.data ?? []).map((a) => (
              <option key={a.id} value={a.id}>
                {a.name}
              </option>
            ))}
          </select>
        </div>
      )}
      {!isOwner && area && ownerPlants.isSuccess && <p className="notice">{t('queue.readOnly')}</p>}
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

      {isOwner && area && (
        <AddForm
          areaId={area.id}
          plantId={area.plant_id}
          isWashroom={isWashroom}
          washers={washers.data ?? []}
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
        <ol className="queue-list" aria-label={t('queue.listTitle')}>
          {items.map((item) => (
            <QueueItemCard
              key={item.id}
              item={item}
              place={places.get(item.id) ?? 0}
              canEdit={isOwner}
              isWashroom={isWashroom}
              washers={washers.data ?? []}
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
