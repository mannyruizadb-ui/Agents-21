import type { KeyValueStore } from '../../lib/scopedStore';

// Home dashboard tiles (owner 2026-11-06, round 2): which tiles a person may see, the default set per
// role, and their own show/hide + order, saved per user per device under
// `plantboard.<userId>.home.v1` (scoped store). Pure except load/save through the given store.

// No "alerts" tile (declutter 2026-11-09): the bell on Home already shows the same count.
export const TILE_IDS = [
  'washers',
  'machinesDown',
  'nextTruck',
  'tasks',
  'dirtyWork',
  'queue',
] as const;
export type TileId = (typeof TILE_IDS)[number];

export type HomeRole = 'owner' | 'manager' | 'other';

export const PREFS_KEY = 'home.v1';

/**
 * Tiles a role may open (the server decides what the screens show; this only hides dead ends).
 * The owner's Home leads with the dashboard, which already shows the washers and the dirty work, so
 * those tiles would only repeat it (declutter 2026-11-09): the owner keeps the four the dashboard
 * doesn't cover.
 */
export function allowedTiles(role: HomeRole): TileId[] {
  if (role === 'other') return ['washers', 'queue', 'nextTruck'];
  if (role === 'owner') return ['machinesDown', 'nextTruck', 'tasks', 'queue'];
  return [...TILE_IDS];
}

/** The default order per role (all allowed tiles shown). */
export function defaultOrder(role: HomeRole): TileId[] {
  switch (role) {
    case 'owner':
      return ['machinesDown', 'nextTruck', 'tasks', 'queue'];
    case 'manager':
      return ['washers', 'machinesDown', 'tasks', 'nextTruck', 'dirtyWork', 'queue'];
    case 'other':
      return ['washers', 'queue', 'nextTruck'];
  }
}

export interface HomePrefs {
  order: TileId[];
  hidden: TileId[];
}

function isTile(x: unknown): x is TileId {
  return typeof x === 'string' && (TILE_IDS as readonly string[]).includes(x);
}

/**
 * Saved prefs made safe for this role: unknown or no-longer-allowed tiles dropped, duplicates
 * removed, and allowed tiles missing from the saved order appended in default order (shown).
 */
export function normalizePrefs(saved: unknown, role: HomeRole): HomePrefs {
  const allowed = new Set(allowedTiles(role));
  const defaults = defaultOrder(role).filter((t) => allowed.has(t));
  const obj = saved && typeof saved === 'object' ? (saved as Record<string, unknown>) : {};
  const rawOrder = Array.isArray(obj.order) ? obj.order : [];
  const rawHidden = Array.isArray(obj.hidden) ? obj.hidden : [];
  const order: TileId[] = [];
  for (const x of rawOrder) if (isTile(x) && allowed.has(x) && !order.includes(x)) order.push(x);
  for (const x of defaults) if (!order.includes(x)) order.push(x);
  const hidden = [...new Set(rawHidden.filter((x): x is TileId => isTile(x) && allowed.has(x)))];
  return { order, hidden };
}

export function loadPrefs(store: KeyValueStore, role: HomeRole): HomePrefs {
  let saved: unknown = null;
  try {
    const raw = store.getItem(PREFS_KEY);
    saved = raw ? (JSON.parse(raw) as unknown) : null;
  } catch {
    saved = null;
  }
  return normalizePrefs(saved, role);
}

export function savePrefs(store: KeyValueStore, prefs: HomePrefs): void {
  store.setItem(PREFS_KEY, JSON.stringify({ order: prefs.order, hidden: prefs.hidden }));
}

/** The tiles to draw, in order. */
export function visibleTiles(prefs: HomePrefs): TileId[] {
  return prefs.order.filter((t) => !prefs.hidden.includes(t));
}

export function toggleTile(prefs: HomePrefs, id: TileId): HomePrefs {
  return prefs.hidden.includes(id)
    ? { ...prefs, hidden: prefs.hidden.filter((x) => x !== id) }
    : { ...prefs, hidden: [...prefs.hidden, id] };
}

/** Move a tile one place up (-1) or down (+1); unchanged at the ends. */
export function moveTile(prefs: HomePrefs, id: TileId, delta: -1 | 1): HomePrefs {
  const i = prefs.order.indexOf(id);
  const j = i + delta;
  if (i < 0 || j < 0 || j >= prefs.order.length) return prefs;
  const order = [...prefs.order];
  [order[i], order[j]] = [order[j] as TileId, order[i] as TileId];
  return { ...prefs, order };
}
