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
  /** Owner 2026-11-06: owners may switch off washer idle alarms (the manager on duty always gets them). */
  notify_washer_idle: boolean;
  /** Owner 2026-11-06: this manager may type the load-out. */
  can_enter_load_out: boolean;
  /** Owner 2026-11-06 (C): per owner, the level of each owner information alert (missing = default). */
  alert_levels?: unknown;
}

/** The owner information alert kinds that have a level (app.owner_alert_kinds). */
export const OWNER_ALERT_KINDS = [
  'customer_delivery',
  'estimate_entered',
  'rewash_added',
  'off_queue_start',
] as const;
export type OwnerAlertKind = (typeof OWNER_ALERT_KINDS)[number];
export type AlertLevel = 'push' | 'quiet' | 'off';
export const ALERT_LEVELS: readonly AlertLevel[] = ['push', 'quiet', 'off'];

/** app.alert_level_default: deliveries buzz; the rest are quiet. */
export function defaultAlertLevel(kind: OwnerAlertKind): AlertLevel {
  return kind === 'customer_delivery' ? 'push' : 'quiet';
}

/** The level a membership's alert_levels gives a kind (missing or unreadable = the default). */
export function alertLevelFor(levels: unknown, kind: OwnerAlertKind): AlertLevel {
  if (levels && typeof levels === 'object' && !Array.isArray(levels)) {
    const v = (levels as Record<string, unknown>)[kind];
    if (v === 'push' || v === 'quiet' || v === 'off') return v;
  }
  return defaultAlertLevel(kind);
}

/** alert_levels with one kind changed (for the optimistic update). */
export function withAlertLevel(
  levels: unknown,
  kind: OwnerAlertKind,
  level: AlertLevel,
): Record<string, AlertLevel> {
  const out: Record<string, AlertLevel> = {};
  for (const k of OWNER_ALERT_KINDS) out[k] = alertLevelFor(levels, k);
  out[kind] = level;
  return out;
}

export interface AlertRow {
  membershipId: string;
  role: string;
  orgWide: boolean;
  on: boolean;
  /** Owner and manager only; anything else can't receive machine-down alerts. */
  canEnable: boolean;
  /** Washer idle alarms: on/off exists for owner memberships only. */
  idleOn: boolean;
  /** Owner information alert levels (meaningful for owner memberships only). */
  levels: Record<OwnerAlertKind, AlertLevel>;
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
      idleOn: m.notify_washer_idle,
      levels: withAlertLevelsAll(m.alert_levels),
    }));
}

function withAlertLevelsAll(levels: unknown): Record<OwnerAlertKind, AlertLevel> {
  return Object.fromEntries(OWNER_ALERT_KINDS.map((k) => [k, alertLevelFor(levels, k)])) as Record<
    OwnerAlertKind,
    AlertLevel
  >;
}
