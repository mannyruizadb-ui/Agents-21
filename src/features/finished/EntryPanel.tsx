import { useEffect, useRef, useState, type FormEvent } from 'react';
import { useTranslation } from 'react-i18next';
import {
  amountKey,
  binAmount,
  isSheetsDoneItem,
  isPackItem,
  looseAmount,
  packsAmount,
  parseCount,
  previewPieces,
  type Amount,
  type FinishItem,
} from './finishedLogic';
import { ItemSwatch } from './ItemSwatch';
import { useItemName } from './useItemName';
import { IconWarning } from '../washroom/Icons';

// The selected item: big name + colour + this shift's total, then the quick adds. Every tap ADDS a line
// (owner 2026-11-10: there is no "edit the total"). Pack items: +1 pack, +5 packs, Packs…, Leftover…;
// items with a bin size: +1 bin (+ Leftover…); Sheet – old (one fixed bin they keep adding to, owner
// 2026-11-10): only Sheets done…, one count of pieces; unit items: one number.

type Mode = 'packs' | 'loose' | 'sheetsDone' | 'unit';

export function EntryPanel({
  item,
  total,
  busy,
  sheetsDoneDefault,
  onAdd,
  onUnpin,
}: {
  item: FinishItem;
  total: number;
  busy: boolean;
  /** "Sheets done…" pre-fill: the last count used for this item on this device. */
  sheetsDoneDefault: number | null;
  onAdd: (amount: Amount, opts?: { sheetsDone?: number }) => void;
  onUnpin: () => void;
}) {
  const { t, i18n } = useTranslation();
  const nameOf = useItemName();
  const num = new Intl.NumberFormat(i18n.language);
  const pack = isPackItem(item);
  const bin = binAmount(item);
  const [mode, setMode] = useState<Mode | null>(pack ? null : 'unit');

  // The page keys this panel by item id, so the mode starts fresh for each item.

  const packSize = item.pack_size ?? 0;
  const sheetsDone = isSheetsDoneItem(item);
  const binned = !!bin || sheetsDone;
  return (
    <section className="card fg-panel" aria-labelledby="fg-item-title">
      <div className="fg-panel-head">
        <ItemSwatch color={item.color_hex} size="lg" />
        <h2 id="fg-item-title" className="fg-item-name">
          {nameOf(item)}
        </h2>
        <p className="fg-item-total">
          <span className="fg-item-total-label">{t('finished.thisShift')}</span>{' '}
          <span className="mono fg-item-total-n">{num.format(total)}</span>
        </p>
      </div>
      <div className="fg-quick" role="group" aria-label={t('finished.quickAdds')}>
        {bin && (
          <button type="button" className="fg-add" disabled={busy} onClick={() => onAdd(bin)}>
            {t('finished.addBin', { n: num.format(bin.loose) })}
          </button>
        )}
        {/* Owner 2026-11-10: sheets go by the bin (+ leftover), never by packs. */}
        {pack && !binned && (
          <>
            <button
              type="button"
              className="fg-add"
              disabled={busy}
              onClick={() => onAdd(packsAmount(item, 1))}
            >
              {t('finished.addPack', { n: num.format(packSize) })}
            </button>
            <button
              type="button"
              className="fg-add"
              disabled={busy}
              onClick={() => onAdd(packsAmount(item, 5))}
            >
              {t('finished.addFivePacks', { n: num.format(packSize * 5) })}
            </button>
          </>
        )}
        {sheetsDone && (
          <button
            type="button"
            className="fg-add secondary"
            aria-expanded={mode === 'sheetsDone'}
            onClick={() => setMode(mode === 'sheetsDone' ? null : 'sheetsDone')}
          >
            {t('finished.sheetsDone')}
          </button>
        )}
        {/* Old sheets are all one count: no "Leftover…" for them (owner 2026-11-10). */}
        {pack && !sheetsDone && (
          <>
            {!binned && (
              <button
                type="button"
                className="fg-add secondary"
                aria-expanded={mode === 'packs'}
                onClick={() => setMode(mode === 'packs' ? null : 'packs')}
              >
                {t('finished.packsMore')}
              </button>
            )}
            <button
              type="button"
              className="fg-add secondary"
              aria-expanded={mode === 'loose'}
              onClick={() => setMode(mode === 'loose' ? null : 'loose')}
            >
              {t('finished.leftoverMore')}
            </button>
          </>
        )}
      </div>
      {mode && (
        <CountForm
          key={`${item.id}-${mode}`}
          item={item}
          mode={mode}
          busy={busy}
          initial={mode === 'sheetsDone' ? sheetsDoneDefault : null}
          onAdd={(amount, n) => {
            onAdd(amount, mode === 'sheetsDone' ? { sheetsDone: n } : undefined);
            if (pack) setMode(null);
          }}
          onCancel={pack ? () => setMode(null) : null}
        />
      )}
      <div className="fg-panel-foot">
        <button type="button" className="secondary" onClick={onUnpin}>
          {t('finished.unpin')}
        </button>
      </div>
    </section>
  );
}

function CountForm({
  item,
  mode,
  busy,
  initial,
  onAdd,
  onCancel,
}: {
  item: FinishItem;
  mode: Mode;
  busy: boolean;
  initial: number | null;
  onAdd: (amount: Amount, n: number) => void;
  onCancel: (() => void) | null;
}) {
  const { t, i18n } = useTranslation();
  const num = new Intl.NumberFormat(i18n.language);
  const [text, setText] = useState(initial !== null ? String(initial) : '');
  const [error, setError] = useState(false);
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (mode !== 'unit') ref.current?.focus();
  }, [mode]);

  const n = parseCount(text);
  const amount: Amount | null =
    n === null ? null : mode === 'packs' ? packsAmount(item, n) : looseAmount(item, n);
  const preview = amount ? amountKey(amount.packs, amount.loose, previewPieces(amount)) : null;
  const looseWarn =
    mode === 'loose' && n !== null && item.pack_size !== null && n >= item.pack_size;
  const id = `fg-count-${mode}`;
  const label =
    mode === 'packs'
      ? t('finished.packsLabel', { n: num.format(item.pack_size ?? 0) })
      : mode === 'loose'
        ? t('finished.leftoverLabel')
        : mode === 'sheetsDone'
          ? t('finished.sheetsDoneLabel')
          : t('finished.unitLabel');

  function submit(e: FormEvent) {
    e.preventDefault();
    if (!amount || n === null) {
      setError(true);
      return;
    }
    setError(false);
    onAdd(amount, n);
    setText(mode === 'sheetsDone' ? String(n) : '');
  }

  return (
    <form className="fg-count" onSubmit={submit} noValidate>
      <label htmlFor={id}>{label}</label>
      <div className="fg-count-row">
        <input
          id={id}
          ref={ref}
          type="text"
          inputMode="numeric"
          pattern="[0-9]*"
          autoComplete="off"
          enterKeyHint="done"
          value={text}
          aria-invalid={error}
          aria-describedby={`${id}-hint`}
          onChange={(e) => {
            setText(e.target.value);
            setError(false);
          }}
        />
        <button type="submit" className="fg-add" disabled={busy}>
          {t('finished.add')}
        </button>
        {onCancel && (
          <button type="button" className="secondary" onClick={onCancel}>
            {t('common.cancel')}
          </button>
        )}
      </div>
      <p id={`${id}-hint`} className={error ? 'error' : 'hint'} aria-live="polite">
        {error
          ? t('finished.countInvalid')
          : preview
            ? t(preview.key, {
                packs: num.format(preview.values.packs),
                loose: num.format(preview.values.loose),
                pieces: num.format(preview.values.pieces),
                count: preview.values.count,
              })
            : mode === 'sheetsDone'
              ? t('finished.sheetsDoneHint')
              : ' '}
      </p>
      {looseWarn && (
        <p className="fg-warn">
          <IconWarning /> {t('finished.looseWarn', { n: num.format(item.pack_size ?? 0) })}
        </p>
      )}
    </form>
  );
}
