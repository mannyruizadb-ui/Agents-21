// Machine-down alert recipients on the People screen (owner 2026-11-04). The flag lives on each
// membership (memberships.notify_machine_down); only owner and manager memberships can be turned on
// (set_alert_recipient enforces it). Pure part, for tests.

export interface AlertMembership {
  id: string;
  user_id: string;
  org_id: string;
  plant_id: string | null;
  role: string;
  notify_machine_down: boolean;
}

export interface AlertRow {
  membershipId: string;
  role: string;
  orgWide: boolean;
  on: boolean;
  /** Owner and manager only; anything else can't receive machine-down alerts. */
  canEnable: boolean;
}

/** This person's active memberships that apply to `plantId` (plant-level or org-wide). */
export function alertRowsFor(
  memberships: readonly AlertMembership[],
  userId: string,
  plant: { id: string; org_id: string },
): AlertRow[] {
  return memberships
    .filter(
      (m) =>
        m.user_id === userId &&
        m.org_id === plant.org_id &&
        (m.plant_id === null || m.plant_id === plant.id),
    )
    .map((m) => ({
      membershipId: m.id,
      role: m.role,
      orgWide: m.plant_id === null,
      on: m.notify_machine_down,
      canEnable: m.role === 'owner' || m.role === 'manager',
    }));
}
