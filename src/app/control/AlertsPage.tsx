import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useRequiredSession } from '../auth/sessionContext';
import { useEffect, useState } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { useLocalNames } from '../../lib/seededNames';
import { userStore } from '../../lib/scopedStore';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow } from '../../lib/useNow';
import {
  readSeen,
  SEEN_KEY,
  seenAfterViewing,
  useMyAlerts,
} from '../../features/alerts/alertsData';
import {
  minutesAgo,
  splitAlerts,
  wallTimeDate,
  type AlertView,
} from '../../features/alerts/alertView';
import { DataAge } from '../../features/washroom/DataAge';
import { useReasonLabeler } from '../../features/washroom/downReasons';
import {
  IconBell,
  IconBins,
  IconIdle,
  IconMachineDown,
  IconReady,
  IconRewash,
  IconTasks,
  IconPeople,
  IconTruck,
} from '../../features/washroom/Icons';
import { useAmountText } from '../../features/estimates/useAmountText';
import { useLocalizedName } from '../../features/washroom/localizedName';
import type { I18nJson } from '../../features/washroom/washroomData';
import { errorMessageKey, unwrap } from '../../features/washroom/rpcError';
import { useMyRoles } from '../../features/washroom/useMyRoles';
import { useAreas } from '../../features/washroom/washroomData';
import '../../lib/forms.css';
import './alerts.css';

// Alerts tab (coordinator 2026-11-06): the push alerts of the last 7 days the user would receive
// (get_my_alerts, owner or manager). Open ones first; every row says what happened, when, and whether
// it is resolved, and a tap opens the screen that fixes it. Wording matches the push notifications.
// No names: the payload never carries any.
// Clear (owner 2026-11-06): each person clears their own list (someone else's stays); only alerts that
// are over can be cleared (the server decides, can_clear). Cleared alerts are hidden, never deleted.

function useTimeText() {
  const { t, i18n } = useTranslation();
  const now = useNow(30_000);
  return (iso: string) => {
    const mins = minutesAgo(iso, now);
    if (mins === null) return '';
    if (mins < 1) return t('common.justNow');
    if (mins < 60) return t('alerts.minAgo', { count: mins });
    const d = new Date(iso);
    const sameDay = mins < 12 * 60;
    return new Intl.DateTimeFormat(i18n.language, {
      ...(sameDay ? {} : { weekday: 'short' }),
      hour: 'numeric',
      minute: '2-digit',
    }).format(d);
  };
}

function KindIcon({ kind }: { kind: AlertView['kind'] }) {
  switch (kind) {
    case 'machine_down':
      return <IconMachineDown size="1.6em" />;
    case 'washer_idle':
      return <IconIdle size="1.6em" />;
    case 'task_assigned':
      return <IconTasks size="1.6em" />;
    case 'task_done':
      return <IconReady size="1.6em" />;
    case 'route_loaded':
      return <IconTruck size="1.6em" />;
    case 'customer_delivery':
      return <IconTruck size="1.6em" />;
    case 'estimate_entered':
      return <IconBins size="1.6em" />;
    case 'rewash_added':
      return <IconRewash size="1.6em" />;
    case 'account_locked':
      return <IconPeople size="1.6em" />;
  }
}

function AlertItem({ a, onClear }: { a: AlertView; onClear?: (id: string) => void }) {
  const { t, i18n } = useTranslation();
  const names = useLocalNames();
  const labeler = useReasonLabeler();
  const timeText = useTimeText();
  const localized = useLocalizedName();
  const { amount } = useAmountText();
  const groupText = (g: { name: string; nameI18n: unknown } | null | undefined) =>
    g ? localized(g.name, g.nameI18n as I18nJson) : '';
  const clock = (d: Date, utc = false) =>
    new Intl.DateTimeFormat(i18n.language, {
      hour: 'numeric',
      minute: '2-digit',
      ...(utc ? { timeZone: 'UTC' } : {}),
    }).format(d);

  let title = '';
  let body = '';
  switch (a.kind) {
    case 'machine_down':
      title = t('alerts.title.machineDown', {
        name: names.machine(a.machineName) || t('alerts.aMachine'),
      });
      body = a.reasonCode ? labeler(a.reasonCode, a.reasonLabels) : '';
      break;
    case 'washer_idle':
      title = t('alerts.title.washerIdle', {
        name: names.machine(a.machineName) || t('alerts.aWasher'),
      });
      break;
    case 'task_assigned':
      title = t('alerts.title.taskNew');
      body = a.taskText ?? '';
      break;
    case 'task_done':
      title = t('alerts.title.taskDone');
      body = a.taskText ?? '';
      break;
    case 'route_loaded': {
      title = t('alerts.title.routeLoaded', {
        name: names.route(a.routeName) || t('alerts.aRoute'),
      });
      const truck = wallTimeDate(a.loadTime);
      body = truck ? t('alerts.truckAt', { time: clock(truck, true) }) : '';
      break;
    }
    case 'customer_delivery': {
      const parts = (a.deliveryLines ?? []).map((l) =>
        t('alerts.deliveryLine', { amount: amount(l.bins, 'bin'), group: groupText(l) }),
      );
      if (a.moreLines) parts.push(t('alerts.moreLines', { count: a.moreLines }));
      const customer =
        localized(a.customerName, a.customerNameI18n as I18nJson) || t('customers.generic');
      title = parts.length
        ? t('alerts.title.customerDelivery', { customer, lines: parts.join(', ') })
        : t('alerts.title.customerDeliveryShort', { customer });
      break;
    }
    case 'estimate_entered':
      title = t('alerts.title.estimateEntered', { count: a.count ?? 0 });
      break;
    case 'rewash_added':
      title = t('alerts.title.rewashAdded', {
        group: groupText(a.group) || t('alerts.aGroup'),
        amount: a.qty !== null && a.qty !== undefined && a.unit ? amount(a.qty, a.unit) : '',
      }).trim();
      break;
    case 'account_locked': {
      title = t('alerts.title.accountLocked', { username: a.username ?? t('alerts.anAccount') });
      const until = a.lockedUntil ? new Date(a.lockedUntil) : null;
      body =
        a.open && until && !Number.isNaN(until.getTime())
          ? t('alerts.lockedUntil', { time: clock(until) })
          : '';
      break;
    }
  }

  const pill = a.open ? (
    <span className={`status-pill ${a.tone}`}>
      <KindIcon kind={a.kind} /> {t(`alerts.state.open.${a.kind}`)}
    </span>
  ) : a.resolved ? (
    <span className="status-pill idle">
      <IconReady /> {t(`alerts.state.resolved.${a.kind}`)}
    </span>
  ) : (
    <span className="status-pill info">
      <IconReady /> {t(`alerts.state.done.${a.kind}`)}
    </span>
  );

  const classes = ['al-row', `tone-${a.tone}`];
  if (a.open) classes.push('open');
  if (a.open && a.kind === 'machine_down') classes.push('stripes-danger');
  if (!a.open) classes.push('past');

  return (
    <li className={classes.join(' ')}>
      <Link to={a.to} className="al-link">
        <span className={`al-icon tone-${a.tone}`} aria-hidden="true">
          <KindIcon kind={a.kind} />
        </span>
        <span className="al-main">
          <span className="al-title">{title}</span>
          {body && <span className="al-body">{body}</span>}
          <span className="al-meta">
            {pill}
            <span className="mono">{timeText(a.createdAt)}</span>
          </span>
        </span>
        <span className="al-chevron" aria-hidden="true">
          ›
        </span>
      </Link>
      {onClear && a.canClear && (
        <div className="al-clear">
          <button type="button" className="secondary" onClick={() => onClear(a.id)}>
            {t('alerts.clear')}
          </button>
        </div>
      )}
    </li>
  );
}

export function AlertsPage() {
  const { t } = useTranslation();
  const session = useRequiredSession();
  const areas = useAreas();
  const plantId = areas.data?.[0]?.plant_id;
  const roles = useMyRoles(session.user.id).rolesFor(plantId);
  const canRead = roles.has('owner') || roles.has('manager');
  const alerts = useMyAlerts(canRead ? plantId : undefined);
  const now = useNow(5_000);
  useLiveRefetch(alerts.refetch, canRead && !!plantId);

  const data = alerts.data;
  const qc = useQueryClient();
  const userId = session.user.id;

  // Opening the tab marks its alerts seen, so the bell badge clears (per user, this device).
  const loadedAt = data?.available ? alerts.dataUpdatedAt : 0;
  useEffect(() => {
    if (!loadedAt || !data?.available) return;
    const store = userStore(userId);
    const next = seenAfterViewing(data.rows, readSeen(store), Date.now());
    if (next !== readSeen(store)) {
      store.setItem(SEEN_KEY, next);
      void qc.invalidateQueries({ queryKey: ['my-alert-count'] });
    }
  }, [loadedAt, data, userId, qc]);
  const split = data?.available ? splitAlerts(data.rows) : null;

  const [clearError, setClearError] = useState<unknown>(null);
  const afterClear = {
    onSuccess: () => setClearError(null),
    onError: (e: unknown) => setClearError(e),
    onSettled: () => {
      void qc.invalidateQueries({ queryKey: ['my-alerts'] });
      void qc.invalidateQueries({ queryKey: ['my-alert-count'] });
    },
  };
  const clearOne = useMutation({
    mutationFn: async (id: string) =>
      unwrap(
        await supabase.rpc('clear_my_alerts', { p_plant_id: plantId ?? '', p_alert_ids: [id] }),
      ),
    ...afterClear,
  });
  const clearAll = useMutation({
    mutationFn: async () =>
      unwrap(await supabase.rpc('clear_my_finished_alerts', { p_plant_id: plantId ?? '' })),
    ...afterClear,
  });
  const clearable = split ? split.earlier.filter((a) => a.canClear).length : 0;
  const clearing = clearOne.isPending || clearAll.isPending;

  return (
    <main className="form-page al-page">
      <div className="al-head">
        <h1>{t('nav.alerts')}</h1>
        {split && (
          <span className="al-count head">
            {t('alerts.openCount', { count: split.open.length })}
          </span>
        )}
      </div>
      {alerts.dataUpdatedAt > 0 && (
        <DataAge
          updatedAt={alerts.dataUpdatedAt}
          now={now}
          isFetching={alerts.isFetching}
          isError={alerts.isError}
        />
      )}
      {alerts.isError && <p className="error">{t(errorMessageKey(alerts.error))}</p>}

      {data && !data.available && (
        <div className="notice al-unavailable">
          <p>
            <IconBell /> {t('alerts.unavailable')}
          </p>
          <Link className="button-link secondary" to="/control/more">
            {t('notifications.title')}
          </Link>
        </div>
      )}

      {split && (
        <>
          <section aria-labelledby="al-open">
            <h2 id="al-open">{t('alerts.openNow')}</h2>
            {split.open.length === 0 ? (
              <p className="al-empty">{t('alerts.noneOpen')}</p>
            ) : (
              <ul className="al-list">
                {split.open.map((a) => (
                  <AlertItem key={a.id} a={a} />
                ))}
              </ul>
            )}
          </section>
          <section aria-labelledby="al-earlier">
            <div className="al-head">
              <h2 id="al-earlier">{t('alerts.earlier')}</h2>
              {clearable > 0 && (
                <button
                  type="button"
                  className="secondary"
                  disabled={clearing}
                  onClick={() => clearAll.mutate()}
                >
                  {t('alerts.clearAll')}
                </button>
              )}
            </div>
            <div role="status" aria-live="polite">
              {clearError !== null && <p className="error">{t(errorMessageKey(clearError))}</p>}
            </div>
            {split.earlier.length === 0 ? (
              <p className="al-empty">{t('alerts.noneEarlier')}</p>
            ) : (
              <ul className="al-list">
                {split.earlier.map((a) => (
                  <AlertItem
                    key={a.id}
                    a={a}
                    onClear={clearing ? undefined : (id) => clearOne.mutate(id)}
                  />
                ))}
              </ul>
            )}
          </section>
          <p className="hint">{t('alerts.pushHint')}</p>
        </>
      )}
    </main>
  );
}
