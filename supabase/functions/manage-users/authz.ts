// Authorization rules for manage-users (PRD A4, owner decision 2026-11-03). Pure functions, so
// authz_test.ts can cover the whole matrix. Caller rows must be ACTIVE ones; target rows are ALL
// of the target's memberships, revoked ones included (security review M3).

export type MemberRole = 'owner' | 'manager' | 'lead' | 'viewer' | 'display';

export interface Membership {
  org_id: string;
  plant_id: string | null; // null = every plant in the org
  role: MemberRole;
  /** Set on revoked rows. Caller lists hold active rows only. */
  revoked_at?: string | null;
}

const isActive = (m: Membership) => m.revoked_at === null || m.revoked_at === undefined;

export interface Plant {
  id: string;
  org_id: string;
}

/** The membership applies to this plant (plant-scoped row, or org-wide row of the plant's org). */
export function inPlantScope(m: Membership, plant: Plant): boolean {
  return m.org_id === plant.org_id && (m.plant_id === null || m.plant_id === plant.id);
}

/** Same rule as SQL app.has_role(plant, '{owner}'). */
export function ownsPlant(caller: Membership[], plant: Plant): boolean {
  return caller.some((m) => m.role === 'owner' && inPlantScope(m, plant));
}

function ownsOrg(caller: Membership[], orgId: string): boolean {
  return caller.some((m) => m.role === 'owner' && m.plant_id === null && m.org_id === orgId);
}

/**
 * May the caller reset the password of, or deactivate, the target from this plant?
 *
 * - The caller owns the plant, and is not the target (own password: change_own_password).
 * - The target has an ACTIVE membership that applies to the plant.
 * - Display device accounts are managed by pairing, never here.
 * - EVERY membership of the target, revoked ones included, is within the caller's owner scope.
 *   Otherwise a plant-scoped owner could reset the password of an org-wide owner (or of someone
 *   in another plant) and take over that account. Revoked rows count because a revoked membership
 *   elsewhere can be restored there, and the password would then be one this owner set.
 * - Co-owners in the same scope ARE manageable (owner decision 2026-11-03, PRD A4).
 *
 * Any "no" is reported to the client the same way as "no such user" (no oracle).
 */
export function canManageTarget(
  callerId: string,
  caller: Membership[],
  targetId: string,
  target: Membership[],
  plant: Plant,
): boolean {
  if (callerId === targetId) return false;
  if (!ownsPlant(caller, plant)) return false;
  if (!target.some((m) => isActive(m) && inPlantScope(m, plant))) return false;
  if (target.some((m) => m.role === 'display')) return false;
  return target.every((m) =>
    m.plant_id === null
      ? ownsOrg(caller, m.org_id)
      : ownsPlant(caller, { id: m.plant_id, org_id: m.org_id }),
  );
}
