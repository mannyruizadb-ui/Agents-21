import { useTranslation } from 'react-i18next';
import { amountKey, buildReview, type FinishItem, type LogLine } from './finishedLogic';
import { ItemSwatch } from './ItemSwatch';
import { IconWarning } from '../washroom/Icons';
import { useItemName } from './useItemName';

/**
 * End-of-shift review: every item with this shift's total ("73 packs + 40 = 7,340"), the stock owned,
 * the number of lines, first → last time and a pace in pieces per hour. Per item per shift, NEVER per
 * person: no names anywhere.
 */
export function ShiftReview({
  lines,
  items,
  hidden,
  hasShift,
  timeFmt,
}: {
  lines: readonly LogLine[];
  items: readonly FinishItem[];
  hidden: boolean;
  hasShift: boolean;
  timeFmt: Intl.DateTimeFormat;
}) {
  const { t, i18n } = useTranslation();
  const nameOf = useItemName();
  const num = new Intl.NumberFormat(i18n.language);
  const byId = new Map(items.map((i) => [i.id, i]));

  if (hidden) {
    return (
      <section className="card fg-review" aria-labelledby="fg-review-title">
        <h2 id="fg-review-title">{t('finished.reviewTitle')}</h2>
        <p className="notice">{t('finished.reviewHidden')}</p>
      </section>
    );
  }
  const rows = buildReview(
    lines,
    items.map((i) => i.id),
  );
  const total = rows.reduce((n, r) => n + r.pieces, 0);
  return (
    <section className="card fg-review" aria-labelledby="fg-review-title">
      <h2 id="fg-review-title">{t('finished.reviewTitle')}</h2>
      {!hasShift ? (
        <p className="hint">{t('finished.noShift')}</p>
      ) : rows.length === 0 ? (
        <p className="hint">{t('finished.reviewEmpty')}</p>
      ) : (
        <>
          <p className="fg-review-total">
            {t('finished.reviewTotal', { pieces: num.format(total), count: rows.length })}
          </p>
          <ul className="fg-review-list">
            {rows.map((r) => {
              const item = byId.get(r.itemTypeId);
              const a = amountKey(r.packs, r.loose, r.pieces);
              return (
                <li key={r.itemTypeId} className="fg-review-row">
                  <p className="fg-review-name">
                    {item && <ItemSwatch color={item.color_hex} />}
                    <span className="head">{nameOf(item) || t('finished.unknownItem')}</span>
                  </p>
                  <p className="fg-review-amount mono">
                    {t(a.key, {
                      packs: num.format(a.values.packs),
                      loose: num.format(a.values.loose),
                      pieces: num.format(a.values.pieces),
                      count: a.values.count,
                    })}
                  </p>
                  <dl className="fg-review-facts">
                    <div>
                      <dt>{t('finished.owned')}</dt>
                      <dd className="mono">
                        {item?.stock_qty != null
                          ? num.format(item.stock_qty)
                          : t('finished.ownedUnknown')}
                      </dd>
                    </div>
                    <div>
                      <dt>{t('finished.lines')}</dt>
                      <dd className="mono">{num.format(r.lines)}</dd>
                    </div>
                    <div>
                      <dt>{t('finished.firstLast')}</dt>
                      <dd className="mono">
                        {t('finished.timeRange', {
                          from: timeFmt.format(new Date(r.first)),
                          to: timeFmt.format(new Date(r.last)),
                        })}
                      </dd>
                    </div>
                    <div>
                      <dt>{t('finished.pace')}</dt>
                      <dd className="mono">
                        {r.pace !== null
                          ? t('finished.perHour', { n: num.format(r.pace) })
                          : t('finished.paceNone')}
                      </dd>
                    </div>
                  </dl>
                  {item?.stock_qty != null && r.pieces > item.stock_qty && (
                    <p className="fg-warn">
                      <IconWarning /> {t('finished.overStock')}
                    </p>
                  )}
                </li>
              );
            })}
          </ul>
        </>
      )}
    </section>
  );
}
