// Which roles the signed-in user holds on a plant (UI gating only: every RPC re-checks the role on
// the server). Pure part separated for tests.

export type MemberRole = 'owner' | 'manager' | 'lead' | 'viewer';

export interface MembershipLike {
  org_id: string;
  plant_id: string | null;
  role: string;
}

/** Roles on `plant` from active memberships: plant-scoped, or org-wide (plant_id null). */
export function rolesOnPlant(
  memberships: readonly MembershipLike[],
  plant: { id: string; org_id: string } | undefined,
): Set<MemberRole> {
  const roles = new Set<MemberRole>();
  if (!plant) return roles;
  for (const m of memberships) {
    if (m.org_id === plant.org_id && (m.plant_id === null || m.plant_id === plant.id)) {
      if (m.role === 'owner' || m.role === 'manager' || m.role === 'lead' || m.role === 'viewer') {
        roles.add(m.role);
      }
    }
  }
  return roles;
}
