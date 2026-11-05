import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../lib/supabase';
import { errorMessageKey, unwrap } from '../washroom/rpcError';
import { alertRowsFor, type AlertMembership } from './alertRecipients';

// "Machine down alerts" on/off per person (owner only: PeoplePage is reachable only by owners, and
// set_alert_recipient re-checks the owner role). The flag is read from memberships directly (RLS:
// owners and managers can read their plant's memberships), not from the manage-users function.

export function useAlertMemberships(plant: { id: string; org_id: string } | undefined) {
  return useQuery({
    queryKey: ['alert-memberships', plant?.id ?? ''],
    enabled: !!plant,
    queryFn: async (): Promise<AlertMembership[]> =>
      unwrap(
        await supabase
          .from('memberships')
          .select('id, user_id, org_id, plant_id, role, notify_machine_down')
          .eq('org_id', plant?.org_id ?? '')
          .is('revoked_at', null),
      ) ?? [],
  });
}

export function AlertToggles({
  userId,
  name,
  plant,
  memberships,
  onStatus,
}: {
  userId: string;
  name: string;
  plant: { id: string; org_id: string };
  memberships: AlertMembership[];
  onStatus: (message: string) => void;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const key = ['alert-memberships', plant.id];
  const rows = alertRowsFor(memberships, userId, plant).filter((r) => r.canEnable || r.on);

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

  if (rows.length === 0) return null;
  return (
    <div className="field check">
      {rows.map((r) => (
        <label key={r.membershipId}>
          <input
            type="checkbox"
            checked={r.on}
            disabled={set.isPending || (!r.on && !r.canEnable)}
            onChange={(e) => set.mutate({ membershipId: r.membershipId, on: e.target.checked })}
          />
          {rows.length > 1
            ? t('people.alertsLabelRole', {
                role: t(`roles.${r.role}`),
                scope: r.orgWide ? t('people.allPlants') : '',
              })
            : t('people.alertsLabel')}
        </label>
      ))}
      <p className="hint">{t('people.alertsHint')}</p>
    </div>
  );
}
