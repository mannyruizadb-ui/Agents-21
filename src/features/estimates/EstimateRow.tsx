import { useTranslation } from 'react-i18next';
import { useAgo } from '../../lib/useAgo';
import { WashGroupLabel } from '../washroom/WashGroupLabel';
import { IconDown, IconUp, IconWarning } from '../washroom/Icons';
import { fractionText, pluralCount } from '../washroom/qtyFormat';
import { useAmountText } from './useAmountText';
import {
  estimateUnits,
  fillAmount,
  parseAmount,
  PARTIALS,
  setPart,
  splitAmount,
  stepFull,
  toLoads,
  washHours,
  type EstimateUnit,
} from './estimateMath';
import type { CurrentEstimate, EstimateGroup } from './estimatesData';
import { wholeLoads } from '../dirtyWork/dirtyWork';

// One wash group in the estimates list (coordinator 2026-11-04 UX round): a compact row (chip, name,
// last value or the unsaved change, chevron). Tapping the row opens its editor; the page keeps only one
// open. Owner 2026-11-09 (review item 4): no one-tap "Nothing waiting" on every row (it read like a
// status and was too easy to hit); "None left (0)" is inside the editor. The last save shows how long
// ago it was ("12 min ago"), so yesterday's value never looks current after midnight. Containers use one stepper ("Full bins: [−1] 2 [+1]")
// plus "Plus a partial bin: none / ¼ / ½ / ¾"; a number box is always there for typing or dictation.
// The answer reads "2½ bins ≈ 5 loads · ≈ 7 h 20 min of washer time": "≈" always, "no number set"
// when a factor is missing. No names anywhere.

export interface Draft {
  unit: EstimateUnit;
  /** What is typed in the number box (kept as text so "2," mid-typing isn't lost). */
  text: string;
}

/** "2½ bins ≈ 5 loads", "3 loads", "Nothing waiting", or "2 bins · loads: no number set". */
function useValueText() {
  const { t } = useTranslation();
  const { fmt, amount } = useAmountText();
  return (qty: number, unit: string, loads: number | null): string => {
    if (qty === 0) return t('estimates.nothingWaiting');
    if (unit === 'load') return amount(qty, 'load');
    // Whole loads, the same rounding as the Dirty work card (review §1: numbers never disagree).
    return loads !== null
      ? t('estimates.approxLoads', {
          amount: amount(qty, unit),
          count: pluralCount(wholeLoads(loads)),
          n: fmt(wholeLoads(loads)),
        })
      : t('estimates.noNumber', { amount: amount(qty, unit) });
  };
}

export function EstimateRow({
  group,
  cycleMinutes,
  last,
  draft,
  open,
  now,
  onToggle,
  onDraft,
}: {
  group: EstimateGroup;
  cycleMinutes: number | null;
  last: CurrentEstimate | undefined;
  draft: Draft | null;
  open: boolean;
  /** epoch ms, for "12 min ago" */
  now: number;
  onToggle: () => void;
  onDraft: (d: Draft | null) => void;
}) {
  const { t } = useTranslation();
  const ago = useAgo();
  const { fmt, hours } = useAmountText();
  const valueText = useValueText();
  const units = estimateUnits(group);
  const unit: EstimateUnit = draft?.unit ?? units[0] ?? 'load';
  const typed = draft !== null && draft.text.trim() !== '';
  const qty = typed ? parseAmount(draft.text) : null;
  const loads = qty === null ? null : toLoads(qty, unit, group);
  const hrs = washHours(loads, cycleMinutes);
  const idBase = `est-${group.id}`;
  const fill = splitAmount(qty ?? 0);
  const changed = typed;

  function setQty(n: number) {
    onDraft({ unit, text: String(n) });
  }

  const rowValue = (() => {
    if (changed) {
      return qty === null ? t('estimates.badAmount') : valueText(qty, unit, loads);
    }
    if (!last) return t('estimates.noEstimateYet');
    const at = ago(Date.parse(last.entered_at), now);
    return t('estimates.lastShort', {
      what: valueText(
        Number(last.qty),
        last.unit,
        last.qty_loads === null ? null : Number(last.qty_loads),
      ),
      at,
    });
  })();

  const answer = (() => {
    if (!typed) return t('estimates.noChange');
    if (qty === null) return t('estimates.badAmount');
    if (qty === 0) return t('estimates.nothingWaiting');
    const parts = [valueText(qty, unit, loads)];
    if (hrs !== null) parts.push(t('estimates.washerTime', { time: hours(hrs) }));
    else if (loads !== null) parts.push(t('estimates.noWashTime'));
    return parts.join(' · ');
  })();

  return (
    <li className={`est-row${open ? ' open' : ''}${changed ? ' changed' : ''}`}>
      <div className="est-row-head">
        <button
          type="button"
          className="est-toggle"
          aria-expanded={open}
          aria-controls={`${idBase}-editor`}
          onClick={onToggle}
        >
          <span className="est-toggle-text">
            <WashGroupLabel
              name={group.name}
              nameI18n={group.name_i18n}
              colorHex={group.color_hex}
              washGroupId={group.id}
            />
            <span className="est-row-value">
              {changed && (
                <>
                  <span className="est-changed">
                    <IconWarning /> {t('estimates.changedTag')}:
                  </span>{' '}
                </>
              )}
              {rowValue}
              {!changed && last?.freshness && last.freshness !== 'ok' && (
                <span className="stale-note">
                  {' '}
                  · <IconWarning /> {t('estimates.old')}
                </span>
              )}
            </span>
          </span>
          {open ? <IconUp className="chevron" /> : <IconDown className="chevron" />}
        </button>
      </div>

      {open && (
        <div id={`${idBase}-editor`} className="est-editor">
          {units.length > 1 && (
            <div role="group" aria-labelledby={`${idBase}-unit`} className="field">
              <p id={`${idBase}-unit`} className="pick-label">
                {t('estimates.countIn')}
              </p>
              <ul className="pick-list unit-picks">
                {units.map((u) => (
                  <li key={u}>
                    <button
                      type="button"
                      aria-pressed={unit === u}
                      onClick={() => onDraft({ unit: u, text: draft?.text ?? '' })}
                    >
                      {t(`rewash.unit.${u}`)}
                    </button>
                  </li>
                ))}
              </ul>
            </div>
          )}

          <div className="stepper" role="group" aria-labelledby={`${idBase}-full`}>
            <span id={`${idBase}-full`} className="pick-label">
              {unit === 'load' ? t('estimates.loadsCount') : t(`estimates.fullCount.${unit}`)}
            </span>
            <button
              type="button"
              className="secondary"
              disabled={fill.full === 0}
              onClick={() => setQty(fillAmount(stepFull(fill, -1)))}
            >
              −1
            </button>
            <output className="stepper-value" aria-live="polite">
              {fmt(fill.full)}
            </output>
            <button
              type="button"
              className="secondary"
              onClick={() => setQty(fillAmount(stepFull(fill, 1)))}
            >
              +1
            </button>
          </div>

          {unit !== 'load' && (
            <div role="group" aria-labelledby={`${idBase}-part`} className="field">
              <p id={`${idBase}-part`} className="pick-label">
                {t(`estimates.partialLabel.${unit}`)}
              </p>
              <ul className="pick-list">
                {PARTIALS.map((p) => (
                  <li key={p}>
                    <button
                      type="button"
                      aria-pressed={typed && qty !== null && fill.part === p}
                      onClick={() => setQty(fillAmount(setPart(fill, p)))}
                    >
                      {p === 0 ? t('estimates.partialNone') : fractionText(p, fmt)}
                    </button>
                  </li>
                ))}
              </ul>
            </div>
          )}

          <div className="field">
            <label htmlFor={`${idBase}-n`}>{t(`rewash.amountLabel.${unit}`)}</label>
            <input
              id={`${idBase}-n`}
              inputMode="decimal"
              autoComplete="off"
              value={draft?.text ?? ''}
              placeholder={last && last.unit === unit ? String(Number(last.qty)) : ''}
              onChange={(e) => onDraft({ unit, text: e.target.value })}
              aria-describedby={`${idBase}-answer`}
              aria-invalid={typed && qty === null}
            />
          </div>

          <p id={`${idBase}-answer`} className="estimate-answer">
            {answer}
          </p>
          {last && !changed && (
            <p className="hint">{t('estimates.lastSaved', { what: rowValue })}</p>
          )}

          <div className="actions">
            <button
              type="button"
              className="secondary"
              onClick={() => onDraft({ unit: 'load', text: '0' })}
            >
              {t('estimates.noneLeft')}
            </button>
            {draft && (
              <button type="button" className="secondary" onClick={() => onDraft(null)}>
                {t('estimates.undoChange')}
              </button>
            )}
            <button type="button" onClick={onToggle}>
              {t('estimates.done')}
            </button>
          </div>
        </div>
      )}
    </li>
  );
}
