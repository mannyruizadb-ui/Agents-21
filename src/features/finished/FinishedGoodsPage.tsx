import { useEffect, useMemo, useRef, useState } from 'react';
import { useSearchParams } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { userStore } from '../../lib/scopedStore';
import { useNow } from '../../lib/useNow';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { DataAge } from '../washroom/DataAge';
import { IconOffline, IconReady, IconWarning } from '../washroom/Icons';
import { errorMessageKey } from '../washroom/rpcError';
import { useMyRoles } from '../washroom/useMyRoles';
import { pickArea, useAreas } from '../washroom/washroomData';
import { usePlant } from '../loadout/loadOutData';
import { useFinishedShift, usePlantItems } from './finishedData';
import { mergeLines } from './finishedLines';
import {
  addWorking,
  bigNumberWarnings,
  isDoubleTap,
  isFinishingItem,
  itemTotal,
  loadSheetsCount,
  loadWorking,
  normalizeWorking,
  previewPieces,
  removeWorking,
  saveSheetsCount,
  saveWorking,
  type Amount,
  type BigWarning,
  type FinishItem,
  type LastAdd,
  type WorkingPrefs,
} from './finishedLogic';
import { useFinishedOutbox, type VoidReason } from './useFinishedOutbox';
import { checkOverStock, useItemStock } from './stockData';
import { EntryPanel } from './EntryPanel';
import { ItemLog } from './ItemLog';
import { ItemPicker } from './ItemPicker';
import { ItemSwatch } from './ItemSwatch';
import { ShiftReview } from './ShiftReview';
import { useItemName } from './useItemName';
import '../../lib/forms.css';
import '../washroom/washroom.css';
import '../estimates/estimates.css';
import './finished.css';

// Finished goods (PRD E1; owner 2026-11-10): the finishing shift manager logs output CONTINUOUSLY as
// product is finished, on the finishing tablet (works on a phone too). Every tap ADDS a line; a wrong
// line is voided and entered again (no "edit the total"). Each line goes through the device outbox
// (stored before the first attempt, client_id kept) and is sent by OutboxRunner. The end-of-shift
// review shows per-item totals and pace, never anything per person.

const UNDO_MS = 10_000;

/** Role gate: owner and managers (the outbox hook only runs for them). */
export function FinishedGoodsPage() {
  const { t } = useTranslation();
  const session = useRequiredSession();
  const areas = useAreas();
  const plantId = areas.data?.[0]?.plant_id;
  const roles = useMyRoles(session.user.id);
  const myRoles = roles.rolesFor(plantId);
  const allowed = myRoles.has('owner') || myRoles.has('manager');
  const area = pickArea(areas.data, 'finishing');

  if (!roles.isSuccess || !areas.isSuccess) {
    return (
      <main className="form-page">
        <p role="status">{t('common.loading')}</p>
      </main>
    );
  }
  if (!allowed || !plantId || !area) {
    return (
      <main className="form-page">
        <h1>{t('finished.title')}</h1>
        <p className="notice">{!area ? t('finished.noArea') : t('finished.notAllowed')}</p>
      </main>
    );
  }
  return (
    <FinishedScreen
      userId={session.user.id}
      plantId={plantId}
      areaId={area.id}
      isOwner={myRoles.has('owner')}
    />
  );
}

interface Toast {
  clientId: string;
  text: string;
  state: 'sending' | 'saved' | 'waiting' | 'undone' | 'error';
  error?: string;
  at: number;
}

interface Confirm {
  item: FinishItem;
  amount: Amount;
  pieces: number;
  double: boolean;
  big: BigWarning[];
  sheetsDone?: number;
}

function FinishedScreen({
  userId,
  plantId,
  areaId,
  isOwner,
}: {
  userId: string;
  plantId: string;
  areaId: string;
  /** Stock owned is owner only (owner 2026-11-10): only the owner's review shows it. */
  isOwner: boolean;
}) {
  const { t, i18n } = useTranslation();
  const nameOf = useItemName();
  const now = useNow(1000);
  const [params, setParams] = useSearchParams();
  const review = params.get('view') === 'review';
  const plant = usePlant(plantId);
  const tz = plant.data?.timezone ?? 'America/New_York';
  const items = usePlantItems(plantId);
  const stock = useItemStock(plantId, isOwner);
  const shift = useFinishedShift(areaId);
  useLiveRefetch(shift.refetch);
  const outbox = useFinishedOutbox(userId);
  const store = useMemo(() => userStore(userId), [userId]);
  const num = useMemo(() => new Intl.NumberFormat(i18n.language), [i18n.language]);
  const timeFmt = useMemo(
    () => new Intl.DateTimeFormat(i18n.language, { timeZone: tz, timeStyle: 'short' }),
    [i18n.language, tz],
  );

  const finishing = useMemo(() => (items.data ?? []).filter(isFinishingItem), [items.data]);
  const byId = useMemo(() => new Map(finishing.map((i) => [i.id, i])), [finishing]);
  const [working, setWorkingState] = useState<WorkingPrefs>(() => loadWorking(store));
  const prefs = items.data ? normalizeWorking(working, new Set(byId.keys())) : working;
  const setWorking = (p: WorkingPrefs) => {
    setWorkingState(p);
    saveWorking(store, p);
  };
  const [picking, setPicking] = useState(false);
  const showPicker = picking || (items.isSuccess && prefs.items.length === 0);
  const selected = prefs.selected ? byId.get(prefs.selected) : undefined;

  const data = shift.data;
  const lines = useMemo(
    () => mergeLines(data, outbox.saved, outbox.pending, areaId),
    [data, outbox.saved, outbox.pending, areaId],
  );
  const pendingCount = outbox.pending.filter((p) => p.areaId === areaId).length;

  const lastAdd = useRef<LastAdd | null>(null);
  const [confirm, setConfirm] = useState<Confirm | null>(null);
  const [toast, setToast] = useState<Toast | null>(null);
  const [busy, setBusy] = useState(false);
  const confirmRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (confirm) confirmRef.current?.focus();
  }, [confirm]);

  // The saved notice (and its Undo) goes away after 10 s; an error stays until the next save.
  const toastVisible =
    toast !== null &&
    (toast.state === 'error' || toast.state === 'sending' || now - toast.at < UNDO_MS);

  async function save(item: FinishItem, amount: Amount, sheetsDone?: number) {
    const pieces = previewPieces(amount);
    const before = itemTotal(lines, item.id);
    // client_id generated BEFORE the first attempt (frontend rules): a retry can never double it.
    const clientId = crypto.randomUUID();
    lastAdd.current = { itemId: item.id, pieces, at: Date.now() };
    if (sheetsDone !== undefined) saveSheetsCount(store, item.id, sheetsDone);
    const text = t('finished.toast', {
      pieces: num.format(pieces),
      name: nameOf(item),
      total: num.format(before + pieces),
    });
    setToast({ clientId, text, state: 'sending', at: Date.now() });
    setBusy(true);
    try {
      const r = await outbox.submit({
        clientId,
        areaId,
        itemTypeId: item.id,
        packs: amount.packs,
        loose: amount.loose,
        packSizeUsed: amount.packSize,
        enteredAt: new Date().toISOString(),
        lastError: null,
      });
      const at = Date.now();
      setToast((cur) =>
        cur && cur.clientId === clientId
          ? r.kind === 'saved'
            ? { ...cur, state: 'saved', at }
            : r.kind === 'waiting'
              ? { ...cur, state: 'waiting', at }
              : r.kind === 'rejected'
                ? {
                    ...cur,
                    state: 'error',
                    error: t(errorMessageKey({ message: r.errorCode })),
                    at,
                  }
                : { ...cur, state: 'error', error: t('finished.notStored'), at }
          : cur,
      );
    } finally {
      setBusy(false);
    }
  }

  async function requestAdd(item: FinishItem, amount: Amount, opts?: { sheetsDone?: number }) {
    const pieces = previewPieces(amount);
    if (pieces <= 0 || busy) return;
    const double = isDoubleTap(lastAdd.current, item.id, pieces, Date.now());
    // The server answers "more than you own?" without revealing the number; offline or on any
    // failure the answer is null and the stock check is skipped (never blocks saving).
    setBusy(true);
    let overStock: boolean | null;
    try {
      overStock = await checkOverStock(item.id, itemTotal(lines, item.id) + pieces);
    } finally {
      setBusy(false);
    }
    const big = bigNumberWarnings(pieces, overStock);
    if (double || big.length > 0) {
      setConfirm({ item, amount, pieces, double, big, sheetsDone: opts?.sheetsDone });
      return;
    }
    void save(item, amount, opts?.sheetsDone);
  }

  async function undo() {
    if (!toast) return;
    const id = toast.clientId;
    const r = await outbox.undo(id);
    lastAdd.current = null;
    setToast((cur) =>
      cur && cur.clientId === id
        ? r === 'failed'
          ? { ...cur, state: 'error', error: t('finished.undoFailed'), at: Date.now() }
          : { ...cur, state: 'undone', text: t('finished.undone'), at: Date.now() }
        : cur,
    );
  }

  const shiftLine = data?.shift
    ? data.is_current
      ? t('finished.shiftHours', {
          name: data.shift.name,
          from: timeFmt.format(new Date(data.shift.starts_at)),
          to: timeFmt.format(new Date(data.shift.ends_at)),
        })
      : t('finished.offShiftLast', { name: data.shift.name })
    : null;

  return (
    <main className="form-page fg-page">
      <header className="fg-header">
        <div className="fg-header-text">
          <h1>{t('finished.title')}</h1>
          <p className="fg-shift">
            {data && !data.is_current ? (
              <span className="badge fg-off">{t('finished.offShift')}</span>
            ) : null}{' '}
            {shiftLine ?? (data ? t('finished.noShift') : t('common.loading'))}
          </p>
          <DataAge
            updatedAt={shift.dataUpdatedAt}
            now={now}
            isFetching={shift.isFetching}
            isError={shift.isError && !!shift.data}
          />
        </div>
        <button
          type="button"
          className={review ? '' : 'secondary'}
          aria-pressed={review}
          onClick={() => setParams(review ? {} : { view: 'review' }, { replace: true })}
        >
          {t('finished.reviewButton')}
        </button>
      </header>

      {shift.isError && !shift.data && <p className="error">{t(errorMessageKey(shift.error))}</p>}
      {data && !data.is_current && !review && (
        <p className="notice">{t('finished.offShiftNotice')}</p>
      )}

      <div role="status" aria-live="polite" className="fg-outbox">
        {pendingCount > 0 && (
          <p className="fg-waiting">
            <IconOffline /> {t('finished.waitingToSend', { count: pendingCount })}
          </p>
        )}
      </div>
      {outbox.rejected.length > 0 && (
        <ul className="fg-rejected" aria-label={t('finished.rejectedTitle')}>
          {outbox.rejected.map((r) => (
            <li key={r.clientId} className="error">
              <IconWarning />{' '}
              {t('finished.rejectedLine', {
                pieces: num.format(r.packs * (r.packSizeUsed ?? 0) + r.loose),
                name: nameOf(byId.get(r.itemTypeId)) || t('finished.unknownItem'),
                why: t(errorMessageKey({ message: r.errorCode })),
              })}{' '}
              <button
                type="button"
                className="secondary"
                onClick={() => outbox.dismiss(r.clientId)}
              >
                {t('finished.dismiss')}
              </button>
            </li>
          ))}
        </ul>
      )}

      {review ? (
        <ShiftReview
          lines={lines}
          items={items.data ?? []}
          stock={isOwner ? (stock.data ?? new Map<string, number>()) : null}
          hidden={data?.entries_hidden ?? false}
          hasShift={!!data?.shift}
          timeFmt={timeFmt}
        />
      ) : (
        <>
          <nav className="fg-working" aria-label={t('finished.workingOn')}>
            <h2 className="visually-hidden">{t('finished.workingOn')}</h2>
            <ul>
              {prefs.items.map((id) => {
                const it = byId.get(id);
                if (!it) return null;
                return (
                  <li key={id}>
                    <button
                      type="button"
                      className="fg-work"
                      aria-pressed={prefs.selected === id}
                      onClick={() => {
                        setWorking({ ...prefs, selected: id });
                        setPicking(false);
                      }}
                    >
                      <ItemSwatch color={it.color_hex} />
                      <span className="fg-work-name">{nameOf(it)}</span>
                      <span className="fg-work-total mono">{num.format(itemTotal(lines, id))}</span>
                    </button>
                  </li>
                );
              })}
              <li>
                <button
                  type="button"
                  className="fg-work fg-work-add secondary"
                  aria-expanded={showPicker}
                  onClick={() => setPicking(!picking)}
                >
                  {t('finished.addItem')}
                </button>
              </li>
            </ul>
          </nav>

          {showPicker && (
            <ItemPicker
              items={finishing}
              pinned={prefs.items}
              onPick={(id) => {
                setWorking(addWorking(prefs, id));
                setPicking(false);
              }}
              onClose={prefs.items.length > 0 ? () => setPicking(false) : null}
            />
          )}

          {confirm && (
            <section
              className="card fg-confirm"
              role="alertdialog"
              aria-labelledby="fg-confirm-title"
              aria-describedby="fg-confirm-body"
            >
              <h2 id="fg-confirm-title">
                <IconWarning />{' '}
                {confirm.double
                  ? t('finished.confirmDouble', { pieces: num.format(confirm.pieces) })
                  : t('finished.confirmTitle')}
              </h2>
              <div id="fg-confirm-body">
                {confirm.double && (
                  <p>
                    {t('finished.confirmDoubleBody', {
                      pieces: num.format(confirm.pieces),
                      name: nameOf(confirm.item),
                    })}
                  </p>
                )}
                {confirm.big.map((w) =>
                  w.kind === 'stock' ? (
                    <p key="stock">{t('finished.confirmStock', { item: nameOf(confirm.item) })}</p>
                  ) : (
                    <p key="single">
                      {t('finished.confirmSingle', {
                        pieces: num.format(w.pieces),
                        name: nameOf(confirm.item),
                      })}
                    </p>
                  ),
                )}
              </div>
              <div className="actions">
                <button
                  ref={confirmRef}
                  type="button"
                  className="fg-add"
                  onClick={() => {
                    const c = confirm;
                    setConfirm(null);
                    void save(c.item, c.amount, c.sheetsDone);
                  }}
                >
                  {confirm.double && confirm.big.length === 0
                    ? t('finished.yesAddAnother')
                    : t('finished.saveAnyway')}
                </button>
                <button type="button" className="secondary" onClick={() => setConfirm(null)}>
                  {t('finished.dontSave')}
                </button>
              </div>
            </section>
          )}

          <div className="fg-toast-region" role="status" aria-live="assertive">
            {toastVisible && toast && (
              <div className={`fg-toast ${toast.state}`}>
                <p className="fg-toast-text">
                  {toast.state === 'error' ? (
                    <IconWarning />
                  ) : toast.state === 'waiting' ? (
                    <IconOffline />
                  ) : (
                    <IconReady />
                  )}{' '}
                  <span>{toast.state === 'error' ? toast.error : toast.text}</span>
                </p>
                {toast.state === 'waiting' && (
                  <p className="fg-toast-sub">{t('finished.savedOnTablet')}</p>
                )}
                {(toast.state === 'saved' || toast.state === 'waiting') && (
                  <span className="fg-undo-wrap">
                    <button type="button" className="secondary fg-undo" onClick={() => void undo()}>
                      {t('finished.undo')}
                    </button>
                    <span className="fg-undo-left mono" aria-hidden="true">
                      {t('finished.secondsLeft', {
                        count: Math.min(
                          UNDO_MS / 1000,
                          Math.max(1, Math.ceil((UNDO_MS - (now - toast.at)) / 1000)),
                        ),
                      })}
                    </span>
                  </span>
                )}
              </div>
            )}
          </div>

          {selected ? (
            <div className="fg-columns">
              <EntryPanel
                key={selected.id}
                item={selected}
                total={itemTotal(lines, selected.id)}
                busy={busy}
                sheetsDoneDefault={loadSheetsCount(store, selected.id)}
                onAdd={(amount, opts) => void requestAdd(selected, amount, opts)}
                onUnpin={() => setWorking(removeWorking(prefs, selected.id))}
              />
              {data?.entries_hidden ? (
                <p className="notice">{t('finished.reviewHidden')}</p>
              ) : (
                <ItemLog
                  lines={lines.filter((l) => l.itemTypeId === selected.id)}
                  itemName={nameOf(selected)}
                  timeFmt={timeFmt}
                  onVoid={(l, reason: VoidReason) =>
                    l.id ? outbox.voidLine(l.id, reason) : Promise.resolve(false)
                  }
                  onRemovePending={async (l) => (await outbox.undo(l.clientId)) !== 'failed'}
                />
              )}
            </div>
          ) : (
            !showPicker && <p className="hint">{t('finished.pickHint')}</p>
          )}
        </>
      )}
    </main>
  );
}
