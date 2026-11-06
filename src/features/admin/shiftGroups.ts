// Usual shifts on the People screen (coordinator 2026-11-06): one checkbox per area + shift name
// ("Washroom · Evening"), covering every variant row of that shift (e.g. the Thursday times). Pure.

export interface ShiftVariant {
  id: string;
  name: string;
  area_name: string;
  start_local: string;
  end_local: string;
  days_of_week: number[];
}

export interface ShiftGroup<S extends ShiftVariant> {
  key: string;
  area_name: string;
  name: string;
  variants: S[];
}

export function groupShifts<S extends ShiftVariant>(shifts: readonly S[]): ShiftGroup<S>[] {
  const groups = new Map<string, ShiftGroup<S>>();
  for (const s of shifts) {
    const key = `${s.area_name}\u0000${s.name}`;
    const g = groups.get(key) ?? { key, area_name: s.area_name, name: s.name, variants: [] };
    g.variants.push(s);
    groups.set(key, g);
  }
  return [...groups.values()]
    .map((g) => ({
      ...g,
      variants: [...g.variants].sort(
        (a, b) =>
          (a.days_of_week[0] ?? 7) - (b.days_of_week[0] ?? 7) ||
          a.start_local.localeCompare(b.start_local),
      ),
    }))
    .sort(
      (a, b) => a.area_name.localeCompare(b.area_name) || earliest(a).localeCompare(earliest(b)),
    );
}

function earliest(g: ShiftGroup<ShiftVariant>): string {
  return g.variants.map((v) => v.start_local).sort()[0] ?? '';
}

/** Is this manager on all, some or none of a group's variants? */
export function groupState(
  assignments: readonly { membership_id: string; shift_id: string; active: boolean }[],
  membershipId: string,
  variantIds: readonly string[],
): 'all' | 'some' | 'none' {
  const on = variantIds.filter((id) =>
    assignments.some((a) => a.membership_id === membershipId && a.shift_id === id && a.active),
  ).length;
  return on === 0 ? 'none' : on === variantIds.length ? 'all' : 'some';
}
