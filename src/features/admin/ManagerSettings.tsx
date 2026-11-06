import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { useLocalNames } from '../../lib/seededNames';
import { supabase } from '../../lib/supabase';
import { errorMessageKey } from '../washroom/rpcError';
import type { AlertMembership } from './alertRecipients';

// Owner-only manager settings on the People screen (owner 2026-11-06):
//  - "Can enter load-out" (memberships.can_enter_load_out; owner-only memberships UPDATE);
//  - which shifts this manager usually works (manager_shift_assignments; owner-only writes). The
//    "manager on duty" for tasks, route loading and alarms follows this schedule.
// Schedule data only: nothing here counts or reports anything per person.

import type { Assignment, ShiftOption } from './useManagerSchedule';
import { groupShifts, groupState } from './shiftGroups';

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
  const names = useLocalNames();
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

  // One checkbox per area + shift name: every variant row (e.g. Thursday's times) changes together.
  const assign = useMutation({
    mutationFn: async (v: { membershipId: string; shiftIds: string[]; on: boolean }) => {
      for (const shiftId of v.shiftIds) {
        const existing = assignments.find(
          (a) =>
            a.membership_id === v.membershipId &&
            a.shift_id === shiftId &&
            !a.id.startsWith('pending-'),
        );
        if (existing && existing.active === v.on) continue;
        if (!existing && !v.on) continue;
        const { error } = existing
          ? await supabase
              .from('manager_shift_assignments')
              .update({ active: v.on })
              .eq('id', existing.id)
          : await supabase.from('manager_shift_assignments').insert({
              org_id: plant.org_id,
              plant_id: plant.id,
              membership_id: v.membershipId,
              shift_id: shiftId,
            });
        if (error) throw error;
      }
    },
    onMutate: async (v) => {
      const key = ['shift-assignments', plant.id];
      await qc.cancelQueries({ queryKey: key });
      const previous = qc.getQueryData<Assignment[]>(key);
      qc.setQueryData<Assignment[]>(key, (list) => {
        let rows = list ?? [];
        for (const shiftId of v.shiftIds) {
          const hit = rows.find(
            (a) => a.membership_id === v.membershipId && a.shift_id === shiftId,
          );
          rows = hit
            ? rows.map((a) => (a === hit ? { ...a, active: v.on } : a))
            : [
                ...rows,
                {
                  id: `pending-${shiftId}`,
                  membership_id: v.membershipId,
                  shift_id: shiftId,
                  active: v.on,
                },
              ];
        }
        return rows;
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
            {groupShifts(shifts).map((g) => {
              const state = groupState(
                assignments,
                m.id,
                g.variants.map((v) => v.id),
              );
              const hintId = `sg-${m.id}-${g.key.replace(/\W+/g, '-')}`;
              return (
                <div className="field check" key={g.key}>
                  <label>
                    <input
                      type="checkbox"
                      checked={state === 'all'}
                      ref={(el) => {
                        if (el) el.indeterminate = state === 'some';
                      }}
                      aria-describedby={hintId}
                      disabled={assign.isPending}
                      onChange={() =>
                        assign.mutate({
                          membershipId: m.id,
                          shiftIds: g.variants.map((v) => v.id),
                          on: state !== 'all',
                        })
                      }
                    />
                    {t('people.shiftGroup', { area: names.area(g.area_name), shift: g.name })}
                    {state === 'some' && ` (${t('people.shiftPartly')})`}
                  </label>
                  <ul id={hintId} className="hint shift-variants">
                    {g.variants.map((v) => (
                      <li key={v.id}>
                        {t('people.shiftVariant', {
                          from: v.start_local.slice(0, 5),
                          to: v.end_local.slice(0, 5),
                          days: dayNames(v.days_of_week),
                        })}
                      </li>
                    ))}
                  </ul>
                </div>
              );
            })}
          </fieldset>
        </div>
      ))}
    </>
  );
}
