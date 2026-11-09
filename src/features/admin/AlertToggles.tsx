import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../lib/supabase';
import { errorMessageKey, unwrap } from '../washroom/rpcError';
import {
  ALERT_LEVELS,
  alertRowsFor,
  OWNER_ALERT_KINDS,
  withAlertLevel,
  type AlertLevel,
  type AlertMembership,
  type OwnerAlertKind,
} from './alertRecipients';
import './alertLevels.css';
import { MoreInfo } from '../../lib/MoreInfo';

// "Machine down alerts" on/off per person (owner only: PeoplePage is reachable only by owners, and
// set_alert_recipient re-checks the owner role). The flag is read from memberships directly (RLS:
// owners and managers can read their plant's memberships), not from the manage-users function.
// "Washer idle alarms" (owner 2026-11-06): on/off for owner memberships only, via
// set_washer_idle_alert; the manager on duty always gets them, so a washer is never left idle unseen.
// Owner information alerts (owner 2026-11-06 C): for owner memberships, Buzz / Quiet / Off per kind
// (AA Linen delivery, estimates entered, rewash added, account locked) via set_alert_level.
// Self-only (owner 2026-11-07): levels and the washer-idle switch show only on the signed-in owner's
// OWN owner rows; machine-down shows for managers and for the owner's own row (never another owner's).

export function AlertToggles({
  userId,
  selfId,
  name,
  plant,
  memberships,
  onStatus,
}: {
  userId: string;
  /** The signed-in owner. */
  selfId: string;
  name: string;
  plant: { id: string; org_id: string };
  memberships: AlertMembership[];
  onStatus: (message: string) => void;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const key = ['alert-memberships', plant.id];
  const all = alertRowsFor(memberships, userId, plant, selfId);
  const rows = all.filter((r) => r.canToggleMachineDown && (r.canEnable || r.on));

  const set = useMutation({
    mutationFn: async (v: { membershipId: string; on: boolean }) =>
      unwrap(
        await supabase.rpc('set_alert_recipient', {
          p_membership_id: v.membershipId,
          p_notify: v.on,
        }),
      ),
    // Optimistic: the box moves at once; it goes back if the server refuses.
    onMutate: async (v) => {
      await qc.cancelQueries({ queryKey: key });
      const previous = qc.getQueryData<AlertMembership[]>(key);
      qc.setQueryData<AlertMembership[]>(key, (list) =>
        list?.map((m) => (m.id === v.membershipId ? { ...m, notify_machine_down: v.on } : m)),
      );
      return { previous };
    },
    onSuccess: (_r, v) =>
      onStatus(v.on ? t('people.alertsOn', { name }) : t('people.alertsOff', { name })),
    onError: (e, _v, ctx) => {
      if (ctx?.previous) qc.setQueryData(key, ctx.previous);
      onStatus(t(errorMessageKey(e)));
    },
    onSettled: () => void qc.invalidateQueries({ queryKey: key }),
  });

  const setIdle = useMutation({
    mutationFn: async (v: { membershipId: string; on: boolean }) =>
      unwrap(
        await supabase.rpc('set_washer_idle_alert', {
          p_membership_id: v.membershipId,
          p_notify: v.on,
        }),
      ),
    onMutate: async (v) => {
      await qc.cancelQueries({ queryKey: key });
      const previous = qc.getQueryData<AlertMembership[]>(key);
      qc.setQueryData<AlertMembership[]>(key, (list) =>
        list?.map((m) => (m.id === v.membershipId ? { ...m, notify_washer_idle: v.on } : m)),
      );
      return { previous };
    },
    onSuccess: (_r, v) =>
      onStatus(v.on ? t('people.idleOn', { name }) : t('people.idleOff', { name })),
    onError: (e, _v, ctx) => {
      if (ctx?.previous) qc.setQueryData(key, ctx.previous);
      onStatus(t(errorMessageKey(e)));
    },
    onSettled: () => void qc.invalidateQueries({ queryKey: key }),
  });
  const setLevel = useMutation({
    mutationFn: async (v: { membershipId: string; kind: OwnerAlertKind; level: AlertLevel }) =>
      unwrap(
        await supabase.rpc('set_alert_level', {
          p_membership_id: v.membershipId,
          p_kind: v.kind,
          p_level: v.level,
        }),
      ),
    onMutate: async (v) => {
      await qc.cancelQueries({ queryKey: key });
      const previous = qc.getQueryData<AlertMembership[]>(key);
      qc.setQueryData<AlertMembership[]>(key, (list) =>
        list?.map((m) =>
          m.id === v.membershipId
            ? { ...m, alert_levels: withAlertLevel(m.alert_levels, v.kind, v.level) }
            : m,
        ),
      );
      return { previous };
    },
    onSuccess: (_r, v) =>
      onStatus(
        t('people.levelSaved', {
          name,
          kind: t(`people.levelKind.${v.kind}`),
          level: t(`people.level.${v.level}`),
        }),
      ),
    onError: (e, _v, ctx) => {
      if (ctx?.previous) qc.setQueryData(key, ctx.previous);
      onStatus(t(errorMessageKey(e)));
    },
    onSettled: () => void qc.invalidateQueries({ queryKey: key }),
  });
  const ownerRows = all.filter((r) => r.ownSettings);

  if (rows.length === 0 && ownerRows.length === 0) return null;

  // One pattern for every alert (review 2026-11-09): a row of big radio buttons per alert. The two
  // on/off alarms offer Buzz | Off; the owner information alerts Buzz | Quiet | Off.
  const onOff = (
    key: string,
    legend: string,
    on: boolean,
    disabled: boolean,
    onPick: (on: boolean) => void,
  ) => (
    <fieldset key={key} className="alert-level">
      <legend>{legend}</legend>
      <div className="segmented two">
        {([true, false] as const).map((v) => (
          <label key={String(v)}>
            <input
              type="radio"
              name={key}
              value={v ? 'push' : 'off'}
              checked={on === v}
              disabled={disabled}
              onChange={() => onPick(v)}
            />
            <span>{t(v ? 'people.level.push' : 'people.level.off')}</span>
          </label>
        ))}
      </div>
    </fieldset>
  );

  return (
    <div className="alert-levels">
      <p className="pick-label">{t('people.alertsTitle')}</p>
      {rows.map((r) =>
        onOff(
          `md-${r.membershipId}`,
          rows.length > 1
            ? t('people.alertsLabelRole', {
                role: t(`roles.${r.role}`),
                scope: r.orgWide ? t('people.allPlants') : '',
              })
            : t('people.alertsLabel'),
          r.on,
          set.isPending || (!r.on && !r.canEnable),
          (on) => set.mutate({ membershipId: r.membershipId, on }),
        ),
      )}
      {ownerRows.map((r) =>
        onOff(`idle-${r.membershipId}`, t('people.idleLabel'), r.idleOn, setIdle.isPending, (on) =>
          setIdle.mutate({ membershipId: r.membershipId, on }),
        ),
      )}
      {ownerRows.map((r) =>
        OWNER_ALERT_KINDS.map((kind) => {
          const group = `lvl-${r.membershipId}-${kind}`;
          return (
            <fieldset key={group} className="alert-level">
              <legend>{t(`people.levelKind.${kind}`)}</legend>
              <div className="segmented">
                {ALERT_LEVELS.map((level) => (
                  <label key={level}>
                    <input
                      type="radio"
                      name={group}
                      value={level}
                      checked={r.levels[kind] === level}
                      disabled={setLevel.isPending}
                      onChange={() =>
                        setLevel.mutate({ membershipId: r.membershipId, kind, level })
                      }
                    />
                    <span>{t(`people.level.${level}`)}</span>
                  </label>
                ))}
              </div>
            </fieldset>
          );
        }),
      )}
      <MoreInfo>
        <p>{t(ownerRows.length > 0 ? 'people.levelsHint' : 'people.buzzHint')}</p>
        {rows.length > 0 && <p>{t('people.alertsHint')}</p>}
        {ownerRows.length > 0 && <p>{t('people.idleHint')}</p>}
      </MoreInfo>
    </div>
  );
}
