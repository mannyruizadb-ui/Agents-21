import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../lib/supabase';
import { errorMessageKey } from '../washroom/rpcError';
import type { AlertMembership } from './alertRecipients';

// Owner-only manager settings on the People screen (owner 2026-11-06):
//  - "Can enter load-out" (memberships.can_enter_load_out; owner-only memberships UPDATE);
//  - which shifts this manager usually works (manager_shift_assignments; owner-only writes). The
//    "manager on duty" for tasks, route loading and alarms follows this schedule.
// Schedule data only: nothing here counts or reports anything per person.

import type { Assignment, ShiftOption } from './useManagerSchedule';

export function ManagerSettings({
  userId,
  name,
  plant,
  memberships,
  shifts,
  assignments,
  onStatus,
}: {
  userId: string;
  name: string;
  plant: { id: string; org_id: string };
  memberships: AlertMembership[];
  shifts: ShiftOption[];
  assignments: Assignment[];
  onStatus: (message: string) => void;
}) {
  const { t, i18n } = useTranslation();
  const qc = useQueryClient();
  const managerRows = memberships.filter(
    (m) =>
      m.user_id === userId &&
      m.role === 'manager' &&
      m.org_id === plant.org_id &&
      (m.plant_id === null || m.plant_id === plant.id),
  );

  const loadOut = useMutation({
    mutationFn: async (v: { membershipId: string; on: boolean }) => {
      const { error } = await supabase
        .from('memberships')
        .update({ can_enter_load_out: v.on })
        .eq('id', v.membershipId);
      if (error) throw error;
    },
    // Optimistic: the box moves at once and goes back if the server refuses.
    onMutate: async (v) => {
      const key = ['alert-memberships', plant.id];
      await qc.cancelQueries({ queryKey: key });
      const previous = qc.getQueryData<AlertMembership[]>(key);
      qc.setQueryData<AlertMembership[]>(key, (list) =>
        list?.map((x) => (x.id === v.membershipId ? { ...x, can_enter_load_out: v.on } : x)),
      );
      return { previous };
    },
    onSuccess: (_r, v) =>
      onStatus(v.on ? t('people.loadOutOn', { name }) : t('people.loadOutOff', { name })),
    onError: (e, _v, ctx) => {
      if (ctx?.previous) qc.setQueryData(['alert-memberships', plant.id], ctx.previous);
      onStatus(t(errorMessageKey(e)));
    },
    onSettled: () => void qc.invalidateQueries({ queryKey: ['alert-memberships', plant.id] }),
  });

  const assign = useMutation({
    mutationFn: async (v: { membershipId: string; shiftId: string; on: boolean }) => {
      const existing = assignments.find(
        (a) =>
          a.membership_id === v.membershipId &&
          a.shift_id === v.shiftId &&
          !a.id.startsWith('pending-'),
      );
      const { error } = existing
        ? await supabase
            .from('manager_shift_assignments')
            .update({ active: v.on })
            .eq('id', existing.id)
        : await supabase.from('manager_shift_assignments').insert({
            org_id: plant.org_id,
            plant_id: plant.id,
            membership_id: v.membershipId,
            shift_id: v.shiftId,
          });
      if (error) throw error;
    },
    onMutate: async (v) => {
      const key = ['shift-assignments', plant.id];
      await qc.cancelQueries({ queryKey: key });
      const previous = qc.getQueryData<Assignment[]>(key);
      qc.setQueryData<Assignment[]>(key, (list) => {
        const rows = list ?? [];
        const hit = rows.find(
          (a) => a.membership_id === v.membershipId && a.shift_id === v.shiftId,
        );
        return hit
          ? rows.map((a) => (a === hit ? { ...a, active: v.on } : a))
          : [
              ...rows,
              {
                id: `pending-${v.shiftId}`,
                membership_id: v.membershipId,
                shift_id: v.shiftId,
                active: v.on,
              },
            ];
      });
      return { previous };
    },
    onSuccess: () => onStatus(t('people.shiftsSaved', { name })),
    onError: (e, _v, ctx) => {
      if (ctx?.previous) qc.setQueryData(['shift-assignments', plant.id], ctx.previous);
      onStatus(t(errorMessageKey(e)));
    },
    onSettled: () => void qc.invalidateQueries({ queryKey: ['shift-assignments', plant.id] }),
  });

  if (managerRows.length === 0) return null;
  const dayNames = (days: number[]) =>
    days
      .map((d) =>
        new Intl.DateTimeFormat(i18n.language, { weekday: 'short', timeZone: 'UTC' }).format(
          new Date(Date.UTC(2026, 10, 1 + d)), // 2026-11-01 is a Sunday
        ),
      )
      .join(' ');

  return (
    <>
      {managerRows.map((m) => (
        <div key={m.id}>
          <div className="field check">
            <label>
              <input
                type="checkbox"
                checked={m.can_enter_load_out}
                disabled={loadOut.isPending}
                onChange={(e) => loadOut.mutate({ membershipId: m.id, on: e.target.checked })}
              />
              {t('people.canEnterLoadOut')}
            </label>
          </div>
          <fieldset className="field" style={{ border: 0, padding: 0, margin: '0.25rem 0' }}>
            <legend>
              <strong>{t('people.shiftsLabel')}</strong>
            </legend>
            <p className="hint">{t('people.shiftsHint')}</p>
            {shifts.map((s) => {
              const on = assignments.some(
                (a) => a.membership_id === m.id && a.shift_id === s.id && a.active,
              );
              return (
                <div className="field check" key={s.id}>
                  <label>
                    <input
                      type="checkbox"
                      checked={on}
                      disabled={assign.isPending}
                      onChange={(e) =>
                        assign.mutate({ membershipId: m.id, shiftId: s.id, on: e.target.checked })
                      }
                    />
                    {t('people.shiftOption', {
                      area: s.area_name,
                      shift: s.name,
                      from: s.start_local.slice(0, 5),
                      to: s.end_local.slice(0, 5),
                      days: dayNames(s.days_of_week),
                    })}
                  </label>
                </div>
              );
            })}
          </fieldset>
        </div>
      ))}
    </>
  );
}
