import { useState, type ReactNode } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useAgo } from '../../lib/useAgo';
import { useMediaQuery } from '../../lib/useMediaQuery';
import { useCustomerNameOf } from '../customers/useCustomerLookup';
import { estimateAges } from '../dashboard/dashboardLogic';
import { DataAge } from '../washroom/DataAge';
import { IconReady, IconWarning } from '../washroom/Icons';
import { safeColor, useLocalizedName } from '../washroom/localizedName';
import { errorMessageKey } from '../washroom/rpcError';
import type { I18nJson } from '../washroom/washroomData';
import { roundedMinutes, type CategoryLine, type GroupLine } from './dirtyWork';
import { useDirtyText } from './useDirtyText';
import type { useDirtyWork } from './useDirtyWork';
import './dirtyWork.css';

// "Dirty work out there" (owner 2026-11-09: "that card is what I meant"; app review §3). One card,
// the same on the owner's Home and at the top of Estimates: categories in a fixed order, units as
// entered, ≈ WHOLE loads, the time ONCE in the header (on the washers up now), group detail under each
// category (shown on a tablet or desktop, behind ▸ on a phone), "Not estimated: N groups ›", and AA
// Linen apart. No colour bars: one neutral share bar per category with the number printed beside it.

const WIDE_QUERY = '(min-width: 48rem)';
export const NEEDS_ESTIMATE_LINK = '/control/estimates?needs=1';

type DirtyState = ReturnType<typeof useDirtyWork>;

function GroupDetail({ groups }: { groups: readonly GroupLine[] }) {
  const { t } = useTranslation();
  const localized = useLocalizedName();
  const text = useDirtyText();
  return (
    <ul className="dirty-groups">
      {groups.map((g) => (
        <li key={g.id}>
          <span
            className="dirty-swatch"
            style={{ backgroundColor: safeColor(g.color) }}
            aria-hidden="true"
          />
          <span className="dirty-group-name">{localized(g.name, g.nameI18n as I18nJson)}</span>{' '}
          <span>{text.amounts(g.amounts)}</span>
          {g.loads === null ? (
            <span className="dirty-unknown"> · {t('dirty.loadsUnknown')}</span>
          ) : (
            g.partlyUnknown && <span className="dirty-unknown"> · {text.loads(g.loads, 1)}</span>
          )}
        </li>
      ))}
    </ul>
  );
}

function CategoryRow({
  line,
  wide,
  showShare,
}: {
  line: CategoryLine;
  wide: boolean;
  showShare: boolean;
}) {
  const { t } = useTranslation();
  const text = useDirtyText();
  const [open, setOpen] = useState(false);
  const name = t(`categories.${line.category}`);
  const detailId = `dirty-detail-${line.category}`;
  const expanded = wide || open;
  const pct = Math.round(line.share * 100);
  const body: ReactNode = (
    <>
      {!wide && (
        <span className="dirty-caret" aria-hidden="true">
          {open ? '▾' : '▸'}
        </span>
      )}
      <span className="dirty-cat-name">{name}</span>
      <span className="dirty-cat-amount">{text.amounts(line.amounts)}</span>
      {showShare && (
        <span className="dirty-share" aria-hidden="true" title={`${pct}%`}>
          {line.loads > 0 && <span style={{ width: `${Math.max(2, pct)}%` }} />}
        </span>
      )}
      <span className="dirty-cat-loads">{text.loads(line.loads, line.unknown)}</span>
    </>
  );
  return (
    <li className="dirty-cat">
      {wide ? (
        <div className="dirty-cat-row">{body}</div>
      ) : (
        <button
          type="button"
          className="dirty-cat-row dirty-cat-button"
          aria-expanded={open}
          aria-controls={detailId}
          onClick={() => setOpen((o) => !o)}
        >
          {body}
        </button>
      )}
      <div id={detailId} hidden={!expanded}>
        <GroupDetail groups={line.groups} />
      </div>
    </li>
  );
}

/**
 * The card body. `title` is the heading (h2); `headerLink` an optional link beside it (Home →
 * Estimates). "Not estimated: N groups ›" opens Estimates › Needs estimate.
 */
export function DirtyWorkSummary({
  dirty,
  now,
  title,
  headingId,
  headerLink,
  showNotEstimated = true,
  extra,
}: {
  dirty: DirtyState;
  now: number;
  title: string;
  headingId: string;
  headerLink?: { to: string; text: string };
  /** false: no "Not estimated" link (Estimates has its own "Needs estimate" filter). */
  showNotEstimated?: boolean;
  /** Rendered under the categories (Estimates: progress and unsaved-changes notes). */
  extra?: ReactNode;
}) {
  const { t, i18n } = useTranslation();
  const text = useDirtyText();
  const ago = useAgo();
  const wide = useMediaQuery(WIDE_QUERY);
  const d = dirty.data;

  const ourIds = new Set<string>();
  if (d) for (const c of d.ours.categories) for (const g of c.groups) ourIds.add(g.id);
  const ages = estimateAges(
    [...(dirty.current.data?.values() ?? [])].filter(
      (e) => Number(e.qty) > 0 && ourIds.has(e.wash_group_id),
    ),
  );
  const timeText = d && dirty.capacityReady ? text.time(d.time) : null;
  const doneAround =
    d && dirty.capacityReady && d.time.minutes !== null && d.time.minutes > 0
      ? new Intl.DateTimeFormat(i18n.language, { hour: 'numeric', minute: '2-digit' }).format(
          new Date(now + roundedMinutes(d.time.minutes) * 60_000),
        )
      : null;

  return (
    <div className="dirty">
      <div className="dirty-head">
        <h2 id={headingId} className="head">
          {title}
        </h2>
        {headerLink && (
          <Link to={headerLink.to} className="dash-link">
            {headerLink.text} <span aria-hidden="true">›</span>
          </Link>
        )}
      </div>

      {dirty.error && !d ? (
        <p className="error" role="alert">
          {t(errorMessageKey(dirty.error))}
        </p>
      ) : !d ? (
        <p role="status">{t('common.loading')}</p>
      ) : (
        <>
          <p className="dirty-total">
            <span className="dirty-total-num">
              {d.ours.categories.length === 0 ? '0' : text.loads(d.ours.loads, d.ours.unknown)}
            </span>
            {d.ours.categories.length === 0 && (
              <span className="dirty-total-unit">{t('dirty.loadsWord')}</span>
            )}
            {timeText && <span className="dirty-time">{timeText}</span>}
            {!dirty.capacityReady && <span className="dirty-time">…</span>}
          </p>
          {doneAround && <p className="dirty-done">{t('home.doneAround', { time: doneAround })}</p>}
          {ages && (
            <p className="dirty-age">
              {t('dash.estimateAges', {
                newest: ago(ages.newest, now),
                oldest: ago(ages.oldest, now),
              })}
            </p>
          )}
          {ages && ages.old > 0 && (
            <p className="dirty-warn">
              <IconWarning /> {t('dash.oldEstimates', { count: ages.old })}
            </p>
          )}

          {d.ours.categories.length === 0 ? (
            <p className="hint">{d.estimated === 0 ? t('dash.noEstimates') : t('dirty.nothing')}</p>
          ) : (
            <ul className="dirty-cats" aria-label={title}>
              {d.ours.categories.map((c) => (
                <CategoryRow key={c.category} line={c} wide={wide} showShare />
              ))}
            </ul>
          )}

          {showNotEstimated && d.notEstimated > 0 && (
            <Link to={NEEDS_ESTIMATE_LINK} className="dash-link dirty-needs-link">
              {t('dirty.notEstimated', { count: d.notEstimated })} <span aria-hidden="true">›</span>
            </Link>
          )}
          {d.ours.unknown > 0 && (
            <p className="hint">
              <IconWarning /> {t('dirty.unknownHint', { count: d.ours.unknown })}
            </p>
          )}
          {d.time.noTime > 0 && (
            <p className="hint">
              <IconWarning /> {t('estimates.noTimeGroups', { count: d.time.noTime })}
            </p>
          )}
          {extra}

          <CustomerWaiting dirty={dirty} headingId={headingId} />
        </>
      )}
      <DataAge
        quiet
        updatedAt={dirty.current.dataUpdatedAt}
        now={now}
        isFetching={dirty.current.isFetching}
        isError={dirty.current.isError}
        refreshSeconds={60}
      />
      {dirty.queue.isError && (
        <DataAge
          quiet
          updatedAt={dirty.queue.dataUpdatedAt}
          now={now}
          isFetching={dirty.queue.isFetching}
          isError={dirty.queue.isError}
        />
      )}
    </div>
  );
}

/** Each outside customer's drop-offs not washed yet (AA Linen), from the open queue. */
export function CustomerWaiting({
  dirty,
  headingId,
  only,
  titleKey = 'dirty.customerTitle',
  level = 3,
}: {
  dirty: DirtyState;
  headingId: string;
  /** Show this customer only (the Estimates AA view). */
  only?: string;
  /** The heading text key ({{name}} = the customer). */
  titleKey?: string;
  /** h3 inside the Dirty work card; h2 as the top of the Estimates AA tab. */
  level?: 2 | 3;
}) {
  const { t } = useTranslation();
  const text = useDirtyText();
  const wide = useMediaQuery(WIDE_QUERY);
  const customerName = useCustomerNameOf();
  const localized = useLocalizedName();
  const d = dirty.data;
  if (!d || !dirty.queueReady) return null;
  const Heading = level === 2 ? 'h2' : 'h3';
  return (
    <>
      {d.customers
        .filter((c) => !only || c.customerId === only)
        .map((c) => {
          const name =
            customerName(dirty.customerGroupId.get(c.customerId)) ?? t('customers.generic');
          return (
            <section
              key={c.customerId}
              className="dirty-cust"
              aria-labelledby={`${headingId}-${c.customerId}`}
            >
              <div className="dirty-cust-head">
                <Heading id={`${headingId}-${c.customerId}`}>{t(titleKey, { name })}</Heading>
                {c.items > 0 && (
                  <span className="dirty-cust-total">{text.loads(c.loads, c.unknown)}</span>
                )}
              </div>
              {c.items === 0 ? (
                <p className="hint">
                  <IconReady /> {t('dash.customerNone')}
                </p>
              ) : (
                <ul className="dirty-cust-lines">
                  {c.categories.map((cat) => (
                    <li key={cat.category}>
                      <span className="dirty-cat-name">{t(`categories.${cat.category}`)}</span>{' '}
                      <span>{text.amounts(cat.amounts)}</span>{' '}
                      <span className="dirty-cust-loads">{text.loads(cat.loads, cat.unknown)}</span>
                      {wide && cat.groups.length > 1 && (
                        <span className="dirty-cust-groups">
                          {' '}
                          (
                          {cat.groups
                            .map((g) => localized(g.name, g.nameI18n as I18nJson))
                            .join(' · ')}
                          )
                        </span>
                      )}
                    </li>
                  ))}
                </ul>
              )}
              {c.unknown > 0 && (
                <p className="hint">
                  <IconWarning /> {t('dirty.customerUnknown')}
                </p>
              )}
            </section>
          );
        })}
    </>
  );
}
