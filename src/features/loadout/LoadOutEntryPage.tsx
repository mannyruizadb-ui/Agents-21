import { useEffect, useId, useRef, useState } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { supabase } from '../../lib/supabase';
import { useNow } from '../../lib/useNow';
import { useLocalizedName } from '../washroom/localizedName';
import { errorMessageKey, unwrap } from '../washroom/rpcError';
import { useAreas } from '../washroom/washroomData';
import {
  loadOutRows,
  localRouteName,
  nextLoadDate,
  parseQty,
  previousLoadDate,
  routesForDate,
} from './loadOutLogic';
import {
  useLoadItems,
  useLoadOutLines,
  useLoadOutPermissions,
  usePlant,
  useRoutes,
  type LoadItem,
  type RouteRow,
} from './loadOutData';
import '../../lib/forms.css';
import './loadout.css';

// Load-out entry (owner 2026-11-06: "must be simple"): the office manager or the owner types what each
// route needs for one loading morning. One card per route (works on a phone); one number per item with
// −1 / +1; "+ Special item" per route; "Same as yesterday" copies the last loading day. Every cell
// saves on its own (optimistic, with its own status); qty 0 = not needed.

type CellStatus = 'saving' | 'saved' | 'error';
interface CellState {
  text: string;
  status: CellStatus;
  error?: string;
}

function cellKey(routeId: string, itemId: string | null, special: string | null) {
  return itemId ? `${routeId}|i|${itemId}` : `${routeId}|s|${special ?? ''}`;
}

/** Per-cell optimistic saving: the latest value wins, saves for one cell run one after another. */
function useCellSaver(plantId: string, loadDate: string, onSaved: () => void) {
  const { t } = useTranslation();
  const [cells, setCells] = useState<Record<string, CellState>>({});
  const chains = useRef(new Map<string, Promise<void>>());
  const timers = useRef(new Map<string, number>());

  useEffect(() => {
    // A new date starts from the server's values.
    setCells({});
  }, [loadDate]);

  function send(
    key: string,
    routeId: string,
    itemId: string | null,
    special: string | null,
    qty: number,
  ) {
    const prev = chains.current.get(key) ?? Promise.resolve();
    const next = prev.then(async () => {
      try {
        unwrap(
          await supabase.rpc('set_load_out_line', {
            p_plant_id: plantId,
            p_load_date: loadDate,
            p_route_id: routeId,
            p_qty: qty,
            ...(itemId ? { p_item_type_id: itemId } : { p_special_text: special ?? '' }),
          }),
        );
        setCells((c) =>
          c[key] && c[key].text === String(qty)
            ? { ...c, [key]: { text: String(qty), status: 'saved' } }
            : c,
        );
        onSaved();
      } catch (e) {
        setCells((c) => ({
          ...c,
          [key]: {
            text: c[key]?.text ?? String(qty),
            status: 'error',
            error: t(errorMessageKey(e)),
          },
        }));
      }
    });
    chains.current.set(key, next);
  }

  /** `immediate` for steppers; typing waits until the person pauses. */
  function change(
    routeId: string,
    itemId: string | null,
    special: string | null,
    text: string,
    immediate: boolean,
  ) {
    const key = cellKey(routeId, itemId, special);
    const qty = parseQty(text);
    if (qty === null) {
      setCells((c) => ({ ...c, [key]: { text, status: 'error', error: t('loadOut.errors.qty') } }));
      return;
    }
    setCells((c) => ({ ...c, [key]: { text, status: 'saving' } }));
    window.clearTimeout(timers.current.get(key));
    if (immediate) send(key, routeId, itemId, special, qty);
    else
      timers.current.set(
        key,
        window.setTimeout(() => send(key, routeId, itemId, special, qty), 700),
      );
  }

  return { cells, change };
}

function QtyCell({
  id,
  label,
  unit,
  value,
  state,
  onChange,
}: {
  id: string;
  label: string;
  unit: string;
  value: number;
  state: CellState | undefined;
  onChange: (text: string, immediate: boolean) => void;
}) {
  const { t } = useTranslation();
  const text = state?.text ?? String(value);
  const n = parseQty(text) ?? value;
  return (
    <div className="lo-cell">
      <label htmlFor={id}>
        {label} <span className="hint">({unit})</span>
      </label>
      <div className="lo-stepper">
        <button
          type="button"
          className="secondary"
          disabled={n <= 0}
          onClick={() => onChange(String(Math.max(0, n - 1)), true)}
        >
          −1
        </button>
        <input
          id={id}
          inputMode="numeric"
          autoComplete="off"
          value={text}
          onChange={(e) => onChange(e.target.value, false)}
          aria-invalid={state?.status === 'error'}
          aria-describedby={`${id}-status`}
        />
        <button type="button" className="secondary" onClick={() => onChange(String(n + 1), true)}>
          +1
        </button>
      </div>
      <p
        id={`${id}-status`}
        className={state?.status === 'error' ? 'error lo-status' : 'hint lo-status'}
      >
        {state?.status === 'saving' && t('loadOut.saving')}
        {state?.status === 'saved' && t('loadOut.saved')}
        {state?.status === 'error' && state.error}
      </p>
    </div>
  );
}

function SpecialForm({ onAdd }: { onAdd: (text: string, qty: number) => void }) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [text, setText] = useState('');
  const [qty, setQty] = useState('1');
  const [error, setError] = useState<string | null>(null);
  const idBase = useId();
  if (!open) {
    return (
      <button type="button" className="secondary" onClick={() => setOpen(true)}>
        {t('loadOut.addSpecial')}
      </button>
    );
  }
  return (
    <div className="lo-special-form">
      <div className="field">
        <label htmlFor={`${idBase}-t`}>{t('loadOut.specialText')}</label>
        <input
          id={`${idBase}-t`}
          value={text}
          maxLength={80}
          autoComplete="off"
          onChange={(e) => setText(e.target.value)}
        />
      </div>
      <div className="field">
        <label htmlFor={`${idBase}-q`}>{t('loadOut.specialQty')}</label>
        <input
          id={`${idBase}-q`}
          inputMode="numeric"
          value={qty}
          onChange={(e) => setQty(e.target.value)}
        />
      </div>
      {error && <p className="error">{error}</p>}
      <div className="actions">
        <button
          type="button"
          onClick={() => {
            const clean = text.replace(/\s+/g, ' ').trim();
            const n = parseQty(qty);
            if (!clean || clean.length > 80) return setError(t('loadOut.errors.special'));
            if (n === null || n === 0) return setError(t('loadOut.errors.qty'));
            onAdd(clean, n);
            setText('');
            setQty('1');
            setError(null);
            setOpen(false);
          }}
        >
          {t('loadOut.add')}
        </button>
        <button type="button" className="secondary" onClick={() => setOpen(false)}>
          {t('common.cancel')}
        </button>
      </div>
    </div>
  );
}

function RouteCard({
  route,
  rows,
  lines,
  cells,
  onChange,
}: {
  route: RouteRow;
  rows: LoadItem[];
  lines: { item_type_id: string | null; special_text: string | null; qty: number }[];
  cells: Record<string, CellState>;
  onChange: (
    itemId: string | null,
    special: string | null,
    text: string,
    immediate: boolean,
  ) => void;
}) {
  const { t, i18n } = useTranslation();
  const localized = useLocalizedName();
  const qtyOf = (itemId: string) => lines.find((l) => l.item_type_id === itemId)?.qty ?? 0;
  const specials = lines.filter((l) => l.special_text && l.qty > 0);
  const added = Object.keys(cells)
    .filter((k) => k.startsWith(`${route.id}|s|`))
    .map((k) => k.slice(`${route.id}|s|`.length))
    .filter((s) => !specials.some((l) => l.special_text === s));
  return (
    <fieldset className="lo-route">
      <legend>
        {localRouteName(route.name, i18n.language)} · {route.load_time.slice(0, 5)}
      </legend>
      {rows.map((item) => (
        <QtyCell
          key={item.id}
          id={`c-${route.id}-${item.id}`}
          label={localized(item.name, item.name_i18n)}
          unit={
            item.count_mode === 'pack'
              ? t('loadOut.unitPacks', { size: item.pack_size ?? '?' })
              : t('loadOut.unitPieces')
          }
          value={qtyOf(item.id)}
          state={cells[cellKey(route.id, item.id, null)]}
          onChange={(text, now) => onChange(item.id, null, text, now)}
        />
      ))}
      {[...specials.map((l) => l.special_text as string), ...added].map((s) => (
        <QtyCell
          key={s}
          id={`c-${route.id}-sp-${s}`}
          label={s}
          unit={t('loadOut.unitSpecial')}
          value={lines.find((l) => l.special_text === s)?.qty ?? 0}
          state={cells[cellKey(route.id, null, s)]}
          onChange={(text, now) => onChange(null, s, text, now)}
        />
      ))}
      <SpecialForm onAdd={(text, qty) => onChange(null, text, String(qty), true)} />
    </fieldset>
  );
}

export function LoadOutEntryPage() {
  const { t, i18n } = useTranslation();
  const qc = useQueryClient();
  const session = useRequiredSession();
  const localized = useLocalizedName();
  const areas = useAreas();
  const plantId = areas.data?.[0]?.plant_id;
  const plant = usePlant(plantId);
  const tz = plant.data?.timezone;
  const nowMs = useNow(60_000);
  const perms = useLoadOutPermissions(session.user.id, plant.data ?? undefined);
  const routes = useRoutes(plantId);
  const items = useLoadItems(plantId);
  const [loadDate, setLoadDate] = useState('');
  const date = loadDate || (tz ? nextLoadDate(nowMs, tz) : '');
  const lines = useLoadOutLines(plantId, date);
  const [addedIds, setAddedIds] = useState<Set<string>>(new Set());
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  const refresh = () => {
    void qc.invalidateQueries({ queryKey: ['load-out-lines', plantId ?? '', date] });
    void qc.invalidateQueries({ queryKey: ['load-out-board'] });
  };
  const saver = useCellSaver(plantId ?? '', date, refresh);

  const dayRoutes = routesForDate(routes.data ?? [], date || '1970-01-01');
  const prev = date ? previousLoadDate(routes.data ?? [], date) : null;
  const rows = loadOutRows(items.data ?? [], lines.data?.recentItemIds ?? new Set(), addedIds);
  const otherItems = (items.data ?? []).filter((i) => !rows.some((r) => r.id === i.id));
  const fmtDate = (d: string) =>
    new Intl.DateTimeFormat(i18n.language, {
      weekday: 'long',
      month: 'short',
      day: 'numeric',
      timeZone: 'UTC',
    }).format(new Date(`${d}T12:00:00Z`));

  const copy = useMutation({
    mutationFn: async () =>
      unwrap(
        await supabase.rpc('copy_load_out_from', {
          p_plant_id: plantId ?? '',
          p_from_date: prev ?? '',
          p_to_date: date,
        }),
      ),
    onSuccess: (n) =>
      setMessage({
        ok: true,
        text: t('loadOut.copied', { count: Number(n ?? 0), from: prev ? fmtDate(prev) : '' }),
      }),
    onError: (e) => setMessage({ ok: false, text: t(errorMessageKey(e)) }),
    onSettled: refresh,
  });

  if (perms.isSuccess && !perms.data.canEnter) {
    return (
      <main className="form-page">
        <p>
          <Link to="/control">{t('common.back')}</Link>
        </p>
        <h1>{t('loadOut.entryTitle')}</h1>
        <p className="notice">{t('loadOut.notAllowed')}</p>
        <p>
          <Link to="/control/load-out">{t('loadOut.boardTitle')}</Link>
        </p>
      </main>
    );
  }

  return (
    <main className="form-page lo-page">
      <p>
        <Link to="/control">{t('common.back')}</Link>
      </p>
      <h1>{t('loadOut.entryTitle')}</h1>
      <div className="field">
        <label htmlFor="lo-date">{t('loadOut.dateLabel')}</label>
        <input
          id="lo-date"
          type="date"
          value={date}
          onChange={(e) => setLoadDate(e.target.value)}
        />
        {date && <p className="hint">{fmtDate(date)}</p>}
      </div>
      <button
        type="button"
        className="lo-copy"
        disabled={!prev || copy.isPending || dayRoutes.length === 0}
        onClick={() => copy.mutate()}
      >
        {t('loadOut.sameAsYesterday')}
      </button>
      {prev && <p className="hint">{t('loadOut.copyHint', { from: fmtDate(prev) })}</p>}
      <div role="status" aria-live="polite">
        {message && <p className={message.ok ? 'notice' : 'error'}>{message.text}</p>}
      </div>
      {(routes.isPending || items.isPending || lines.isPending) && (
        <p role="status">{t('common.loading')}</p>
      )}
      {date && routes.isSuccess && dayRoutes.length === 0 && (
        <p className="notice">{t('loadOut.noRoutes')}</p>
      )}
      <div className="lo-routes">
        {dayRoutes.map((r) => (
          <RouteCard
            key={r.id}
            route={r}
            rows={rows}
            lines={(lines.data?.lines ?? []).filter((l) => l.route_id === r.id)}
            cells={Object.fromEntries(
              Object.entries(saver.cells).filter(([k]) => k.startsWith(`${r.id}|`)),
            )}
            onChange={(itemId, special, text, now) =>
              saver.change(r.id, itemId, special, text, now)
            }
          />
        ))}
      </div>
      {dayRoutes.length > 0 && otherItems.length > 0 && (
        <div className="field">
          <label htmlFor="lo-add-row">{t('loadOut.addRow')}</label>
          <select
            id="lo-add-row"
            value=""
            onChange={(e) => e.target.value && setAddedIds(new Set([...addedIds, e.target.value]))}
          >
            <option value="">{t('queue.choose')}</option>
            {otherItems.map((i) => (
              <option key={i.id} value={i.id}>
                {localized(i.name, i.name_i18n)}
              </option>
            ))}
          </select>
        </div>
      )}
      <p>
        <Link to="/control/load-out">{t('loadOut.boardTitle')}</Link>
      </p>
    </main>
  );
}
