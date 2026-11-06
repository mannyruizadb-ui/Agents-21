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
  groupSizes,
  loadOutRows,
  localRouteName,
  nextLoadDate,
  parseQty,
  previousLoadDate,
  routesForDate,
  splitSize,
  wallClock,
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

// Load-out entry (owner 2026-11-06: "must be simple"; redesign 2026-11-06): the office manager or the
// owner types what each route needs for one loading morning. "Same as yesterday" on top, a summary
// (routes filled, packs and pieces), then one card per route with its total; one row per item with
// −1 / +1, sized items (Butcher coat M / L / XL) under one heading with their total; "+ Special item"
// per route. Every cell saves on its own (optimistic, with its own status); qty 0 = not needed.

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
  compact = false,
}: {
  id: string;
  label: string;
  unit: string;
  value: number;
  state: CellState | undefined;
  onChange: (text: string, immediate: boolean) => void;
  /** a size inside a group: the label is just the size */
  compact?: boolean;
}) {
  const { t } = useTranslation();
  const text = state?.text ?? String(value);
  const n = parseQty(text) ?? value;
  return (
    <div className={compact ? 'lo-row compact' : 'lo-row'}>
      <div className="lo-row-label">
        <label htmlFor={id}>{label}</label>
        {unit && <span className="lo-unit">{unit}</span>}
        <span
          id={`${id}-status`}
          className={state?.status === 'error' ? 'error lo-status' : 'lo-status'}
        >
          {state?.status === 'saving' && t('loadOut.saving')}
          {state?.status === 'saved' && t('loadOut.saved')}
          {state?.status === 'error' && state.error}
        </span>
      </div>
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
          className="mono"
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
    </div>
  );
}

type Line = { item_type_id: string | null; special_text: string | null; qty: number };

/** The quantity a cell shows: what is being typed when it reads as a number, else the server's. */
function shownQty(cells: Record<string, CellState>, key: string, server: number): number {
  const c = cells[key];
  return c ? (parseQty(c.text) ?? server) : server;
}

/** Packs and pieces on a set of lines (special items count as pieces). */
function sumUnits(
  rows: readonly LoadItem[],
  qty: (item: LoadItem) => number,
  specials: number,
): { packs: number; pieces: number } {
  let packs = 0;
  let pieces = specials;
  for (const r of rows) {
    if (r.count_mode === 'pack') packs += qty(r);
    else pieces += qty(r);
  }
  return { packs, pieces };
}

function useUnitsText() {
  const { t } = useTranslation();
  return ({ packs, pieces }: { packs: number; pieces: number }) =>
    [
      packs > 0 && t('loadOut.packsShort', { count: packs }),
      pieces > 0 && t('loadOut.piecesShort', { count: pieces }),
    ]
      .filter(Boolean)
      .join(' · ') || t('loadOut.empty');
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
  lines: Line[];
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
  const unitsText = useUnitsText();
  const serverQty = (itemId: string) => lines.find((l) => l.item_type_id === itemId)?.qty ?? 0;
  const qtyOf = (item: LoadItem) =>
    shownQty(cells, cellKey(route.id, item.id, null), serverQty(item.id));
  const specials = lines.filter((l) => l.special_text && l.qty > 0);
  const added = Object.keys(cells)
    .filter((k) => k.startsWith(`${route.id}|s|`))
    .map((k) => k.slice(`${route.id}|s|`.length))
    .filter((s) => !specials.some((l) => l.special_text === s));
  const specialNames = [...specials.map((l) => l.special_text as string), ...added];
  const specialQty = specialNames.reduce(
    (n, s) =>
      n +
      shownQty(
        cells,
        cellKey(route.id, null, s),
        lines.find((l) => l.special_text === s)?.qty ?? 0,
      ),
    0,
  );
  const units = sumUnits(rows, qtyOf, specialQty);
  const empty = units.packs === 0 && units.pieces === 0;
  const unitOf = (item: LoadItem) =>
    item.count_mode === 'pack'
      ? t('loadOut.unitPacks', { size: item.pack_size ?? '?' })
      : t('loadOut.unitPieces');
  const headId = `lo-route-${route.id}`;

  return (
    <section className={empty ? 'lo-route empty' : 'lo-route'} aria-labelledby={headId}>
      <div className="lo-route-head">
        <h2 id={headId} className="head">
          {localRouteName(route.name, i18n.language)}
          <span className="lo-time-chip mono">{wallClock(route.load_time, i18n.language)}</span>
        </h2>
        <span className={empty ? 'status-pill idle' : 'status-pill info'}>{unitsText(units)}</span>
      </div>
      {groupSizes(rows).map((g) =>
        g.kind === 'single' ? (
          <QtyCell
            key={g.item.id}
            id={`c-${route.id}-${g.item.id}`}
            label={localized(g.item.name, g.item.name_i18n)}
            unit={unitOf(g.item)}
            value={serverQty(g.item.id)}
            state={cells[cellKey(route.id, g.item.id, null)]}
            onChange={(text, now) => onChange(g.item.id, null, text, now)}
          />
        ) : (
          <fieldset key={g.base} className="lo-sizes">
            <legend>
              <span>
                {(g.items[0] &&
                  splitSize(localized(g.items[0].item.name, g.items[0].item.name_i18n))?.base) ??
                  g.base}
              </span>
              <span className="lo-sizes-total mono">
                {t('loadOut.groupTotal', {
                  count: g.items.reduce((n, x) => n + qtyOf(x.item), 0),
                })}
              </span>
            </legend>
            {g.items.map(({ item, size }) => (
              <QtyCell
                key={item.id}
                id={`c-${route.id}-${item.id}`}
                label={t('loadOut.size', { size })}
                unit={unitOf(item)}
                value={serverQty(item.id)}
                state={cells[cellKey(route.id, item.id, null)]}
                onChange={(text, now) => onChange(item.id, null, text, now)}
                compact
              />
            ))}
          </fieldset>
        ),
      )}
      {specialNames.map((s) => (
        <div key={s} className="lo-special">
          <QtyCell
            id={`c-${route.id}-sp-${s}`}
            label={`★ ${s}`}
            unit={t('loadOut.unitSpecial')}
            value={lines.find((l) => l.special_text === s)?.qty ?? 0}
            state={cells[cellKey(route.id, null, s)]}
            onChange={(text, now) => onChange(null, s, text, now)}
          />
        </div>
      ))}
      <SpecialForm onAdd={(text, qty) => onChange(null, text, String(qty), true)} />
    </section>
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
  const unitsText = useUnitsText();
  const allLines = lines.data?.lines ?? [];
  const perRoute = dayRoutes.map((r) => {
    const mine = allLines.filter((l) => l.route_id === r.id);
    const q = (item: LoadItem) =>
      shownQty(
        saver.cells,
        cellKey(r.id, item.id, null),
        mine.find((l) => l.item_type_id === item.id)?.qty ?? 0,
      );
    const sp = mine
      .filter((l) => l.special_text)
      .reduce((n, l) => n + shownQty(saver.cells, cellKey(r.id, null, l.special_text), l.qty), 0);
    return sumUnits(rows, q, sp);
  });
  const filled = perRoute.filter((u) => u.packs + u.pieces > 0).length;
  const grand = perRoute.reduce(
    (a, u) => ({ packs: a.packs + u.packs, pieces: a.pieces + u.pieces }),
    { packs: 0, pieces: 0 },
  );
  const cellList = Object.values(saver.cells);
  const saveState = cellList.some((c) => c.status === 'error')
    ? 'error'
    : cellList.some((c) => c.status === 'saving')
      ? 'saving'
      : cellList.length > 0
        ? 'saved'
        : null;
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
        <h1>{t('loadOut.entryTitle')}</h1>
        <p className="notice">{t('loadOut.notAllowed')}</p>
        <p>
          <Link className="button-link secondary" to="/control/load-out">
            {t('loadOut.boardTitle')}
          </Link>
        </p>
      </main>
    );
  }

  return (
    <main className="form-page lo-page">
      <h1>{t('loadOut.entryTitle')}</h1>
      <div className="lo-date-row">
        <div className="field">
          <label htmlFor="lo-date">{t('loadOut.dateLabel')}</label>
          <input
            id="lo-date"
            type="date"
            value={date}
            onChange={(e) => setLoadDate(e.target.value)}
          />
        </div>
        {date && <p className="lo-date-chip head">{fmtDate(date)}</p>}
      </div>
      <button
        type="button"
        className="lo-copy"
        disabled={!prev || copy.isPending || dayRoutes.length === 0}
        onClick={() => copy.mutate()}
      >
        <span className="lo-copy-title head">{t('loadOut.sameAsYesterday')}</span>
        {prev && (
          <span className="lo-copy-hint">{t('loadOut.copyHint', { from: fmtDate(prev) })}</span>
        )}
      </button>
      <div role="status" aria-live="polite">
        {message && <p className={message.ok ? 'notice' : 'error'}>{message.text}</p>}
      </div>
      {dayRoutes.length > 0 && (
        <div className="lo-summary">
          <p>
            <strong className="head">
              {t('loadOut.routesFilled', { filled, total: dayRoutes.length })}
            </strong>
          </p>
          <p className="mono lo-summary-units">{unitsText(grand)}</p>
          <p
            className={saveState === 'error' ? 'lo-save-state error' : 'lo-save-state'}
            aria-live="polite"
          >
            {saveState === 'saving' && t('loadOut.saving')}
            {saveState === 'saved' && t('loadOut.allSaved')}
            {saveState === 'error' && t('loadOut.someNotSaved')}
          </p>
        </div>
      )}
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
        <Link className="button-link secondary" to="/control/load-out">
          {t('loadOut.boardTitle')}
        </Link>
      </p>
    </main>
  );
}
