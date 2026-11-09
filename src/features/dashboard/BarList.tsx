import { useState, type ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import { safeColor } from '../washroom/localizedName';
import { barPct, needsOutline, topN } from './dashboardLogic';

// Horizontal bar chart in plain HTML/CSS (no chart library; dataviz skill mark specs): one row per
// thing, bars ≤ 24 px from one baseline with a 4 px rounded data end, the name and the value always
// written in text (never color alone), so the list itself is the table view. Values are sorted by
// the caller.

export interface Bar {
  id: string;
  name: string;
  value: number;
  /** The value as words ("≈ 2 h 10 min", "14 loads"). */
  valueText: string;
  /** Extra words after the value ("+ 1 rewash"). */
  extra?: string;
  /** Bar fill; null = the single-series accent. */
  color: string | null;
  /** Shown after the name (the AA Linen badge). */
  tag?: ReactNode;
}

// The dashboard card surface (--c-surface): dark goods colors get an outline against it.
const SURFACE = '#171f33';

export function BarList({
  bars,
  label,
  initial = 8,
}: {
  bars: Bar[];
  label: string;
  initial?: number;
}) {
  const { t } = useTranslation();
  const [all, setAll] = useState(false);
  const max = bars.reduce((m, b) => Math.max(m, b.value), 0);
  const { shown, rest } = topN(bars, all ? bars.length : initial);
  return (
    <>
      <ol className="dash-bars" aria-label={label}>
        {shown.map((b) => {
          const color = b.color ? safeColor(b.color) : null;
          const words = `${b.name}: ${b.valueText}${b.extra ? ` ${b.extra}` : ''}`;
          return (
            <li key={b.id} title={words}>
              <span className="dash-bar-name">
                {b.name}
                {b.tag}
              </span>
              <span className="dash-bar-track" aria-hidden="true">
                <span
                  className={`dash-bar${color && needsOutline(color, SURFACE) ? ' outlined' : ''}${color ? '' : ' accent'}`}
                  style={{
                    width: `${barPct(b.value, max)}%`,
                    ...(color ? { backgroundColor: color } : {}),
                  }}
                />
              </span>
              <span className="dash-bar-value">
                <span className="mono">{b.valueText}</span>
                {b.extra && <span className="dash-bar-extra"> {b.extra}</span>}
              </span>
            </li>
          );
        })}
      </ol>
      {(rest > 0 || all) && bars.length > initial && (
        <button type="button" className="secondary dash-more" onClick={() => setAll((v) => !v)}>
          {all ? t('dash.showFewer') : t('dash.showAll', { count: bars.length })}
        </button>
      )}
    </>
  );
}
