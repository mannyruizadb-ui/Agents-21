import { useTranslation } from 'react-i18next';
import { WashGroupLabel } from '../washroom/WashGroupLabel';
import { IconWarning } from '../washroom/Icons';
import { fractionText, pluralCount } from '../washroom/qtyFormat';
import { useAmountText } from './useAmountText';
import {
  addFull,
  estimateUnits,
  fillAmount,
  parseAmount,
  setPart,
  splitAmount,
  toLoads,
  washHours,
  type EstimateUnit,
} from './estimateMath';
import type { CurrentEstimate, EstimateGroup } from './estimatesData';

// One wash group's estimate card (owner 2026-11-04: clear, not just +/−). Choose the container the
// group allows, tap "+1" per full one and ¼ ½ ¾ Full for a partly full one, or type a number. The card answers
// live: "2½ bins ≈ 5 loads · ≈ 4 h 55 min of washing". "≈" always; "no number set" when a factor is
// missing. The last estimate shows with its time only (no names).

export interface Draft {
  unit: EstimateUnit;
  /** What is typed in the number box (kept as text so "2," mid-typing isn't lost). */
  text: string;
}

const FILL_PICKS = [0.25, 0.5, 0.75, 1] as const;

export function EstimateCard({
  group,
  cycleMinutes,
  last,
  draft,
  onDraft,
  now,
}: {
  group: EstimateGroup;
  cycleMinutes: number | null;
  last: CurrentEstimate | undefined;
  draft: Draft | null;
  onDraft: (d: Draft | null) => void;
  now: number;
}) {
  const { t, i18n } = useTranslation();
  const { fmt, amount, hours } = useAmountText();
  const units = estimateUnits(group);
  const unit: EstimateUnit = draft?.unit ?? units[0] ?? 'load';
  const qty = draft ? parseAmount(draft.text) : null;
  const loads = qty === null ? null : toLoads(qty, unit, group);
  const hrs = washHours(loads, cycleMinutes);
  const idBase = `est-${group.id}`;

  function setQty(n: number) {
    onDraft({ unit, text: String(n) });
  }

  const lastText = (() => {
    if (!last) return t('estimates.noEstimateYet');
    const at = new Intl.DateTimeFormat(i18n.language, {
      hour: 'numeric',
      minute: '2-digit',
    }).format(new Date(last.entered_at));
    const mins = Math.max(0, Math.floor((now - Date.parse(last.entered_at)) / 60000));
    const ago =
      mins < 60
        ? t('estimates.minutesAgo', { count: mins })
        : t('estimates.hoursAgo', { count: Math.floor(mins / 60) });
    const what =
      Number(last.qty) === 0
        ? t('estimates.nothingWaiting')
        : last.unit === 'load'
          ? amount(Number(last.qty), 'load')
          : last.qty_loads !== null
            ? t('estimates.approxLoads', {
                amount: amount(Number(last.qty), last.unit),
                count: pluralCount(Number(last.qty_loads)),
                n: fmt(Number(last.qty_loads)),
              })
            : t('estimates.noNumber', { amount: amount(Number(last.qty), last.unit) });
    return t('estimates.lastValue', { what, at, ago });
  })();

  return (
    <li
      className={draft ? 'estimate-card changed' : 'estimate-card'}
      aria-labelledby={`${idBase}-h`}
    >
      <h2 id={`${idBase}-h`}>
        <WashGroupLabel name={group.name} nameI18n={group.name_i18n} colorHex={group.color_hex} />
      </h2>
      <p className="hint">
        {lastText}
        {last && last.freshness && last.freshness !== 'ok' && (
          <span className="stale-note">
            {' '}
            <IconWarning /> {t('estimates.old')}
          </span>
        )}
      </p>

      {units.length > 1 && (
        <div role="group" aria-labelledby={`${idBase}-unit`} className="field">
          <p id={`${idBase}-unit`} className="pick-label">
            {t('estimates.countIn')}
          </p>
          <ul className="pick-list">
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

      {unit !== 'load' ? (
        <div role="group" aria-labelledby={`${idBase}-fill`} className="field">
          <p id={`${idBase}-fill`} className="pick-label">
            {t('estimates.howFullPart', { unit: t(`estimates.unitOne.${unit}`) })}
          </p>
          <ul className="pick-list fill-picks">
            {FILL_PICKS.map((p) => (
              <li key={p}>
                <button
                  type="button"
                  aria-pressed={qty !== null && qty > 0 && splitAmount(qty).part === p}
                  onClick={() => setQty(fillAmount(setPart(splitAmount(qty ?? 0), p)))}
                >
                  {p === 1 ? t('rewash.full') : fractionText(p, fmt)}
                </button>
              </li>
            ))}
            <li>
              <button
                type="button"
                className="secondary"
                onClick={() => setQty(fillAmount(addFull(splitAmount(qty ?? 0))))}
              >
                {t(`estimates.addOne.${unit}`)}
              </button>
            </li>
          </ul>
        </div>
      ) : (
        <div className="actions">
          <button type="button" className="secondary" onClick={() => setQty((qty ?? 0) + 1)}>
            {t('estimates.addOne.load')}
          </button>
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
          aria-invalid={draft !== null && draft.text !== '' && qty === null}
        />
      </div>

      <p id={`${idBase}-answer`} className="estimate-answer">
        {draft === null || draft.text === ''
          ? t('estimates.noChange')
          : qty === null
            ? t('estimates.badAmount')
            : qty === 0
              ? t('estimates.nothingWaiting')
              : [
                  unit === 'load'
                    ? amount(qty, 'load')
                    : loads !== null
                      ? t('estimates.approxLoads', {
                          amount: amount(qty, unit),
                          count: pluralCount(loads),
                          n: fmt(loads),
                        })
                      : t('estimates.noNumber', { amount: amount(qty, unit) }),
                  hrs !== null
                    ? t('estimates.washing', { time: hours(hrs) })
                    : loads !== null
                      ? t('estimates.noWashTime')
                      : null,
                ]
                  .filter(Boolean)
                  .join(' · ')}
      </p>

      <div className="actions">
        <button
          type="button"
          className="secondary"
          onClick={() => onDraft({ unit: 'load', text: '0' })}
        >
          {t('estimates.nothingWaitingButton')}
        </button>
        {draft && (
          <button type="button" className="secondary" onClick={() => onDraft(null)}>
            {t('estimates.undoChange')}
          </button>
        )}
      </div>
      {draft && draft.text !== '' && qty !== null && (
        <p className="changed-note">
          <IconWarning /> {t('estimates.notSaved')}
        </p>
      )}
    </li>
  );
}
