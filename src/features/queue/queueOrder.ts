// Queue ordering for the up/down buttons (PRD C2; drag-and-drop alternative). The board order is
// RUSH items first, then normal items; each is its own partition and an item only moves inside its
// partition (reorder_queue_item takes "put me directly below p_after_id", or null = top).

export interface Orderable {
  id: string;
  is_rush: boolean;
}

export type Direction = 'up' | 'down';

/**
 * The p_after_id for moving `id` one step up or down within its partition. Returns undefined when
 * the move is impossible (already first/last, or not found); null means "to the top".
 */
export function moveAfterId<T extends Orderable>(
  items: readonly T[],
  id: string,
  dir: Direction,
): string | null | undefined {
  const item = items.find((i) => i.id === id);
  if (!item) return undefined;
  const part = items.filter((i) => i.is_rush === item.is_rush);
  const idx = part.findIndex((i) => i.id === id);
  if (dir === 'up') {
    if (idx <= 0) return undefined;
    return idx >= 2 ? (part[idx - 2]?.id ?? null) : null;
  }
  if (idx >= part.length - 1) return undefined;
  return part[idx + 1]?.id;
}

/** Can `id` move in `dir`? (Disables the button rather than offering a no-op.) */
export function canMove<T extends Orderable>(
  items: readonly T[],
  id: string,
  dir: Direction,
): boolean {
  return moveAfterId(items, id, dir) !== undefined;
}

/**
 * The list after moving `id` directly below `afterId` (or to the top of its partition when null),
 * for the optimistic update. The server's order wins on the next refetch.
 */
export function applyMove<T extends Orderable>(
  items: readonly T[],
  id: string,
  afterId: string | null,
): T[] {
  const item = items.find((i) => i.id === id);
  if (!item) return [...items];
  const rest = items.filter((i) => i.id !== id);
  let insertAt: number;
  if (afterId === null) {
    insertAt = rest.findIndex((i) => i.is_rush === item.is_rush);
    if (insertAt < 0) insertAt = item.is_rush ? 0 : rest.length;
  } else {
    const anchor = rest.findIndex((i) => i.id === afterId);
    if (anchor < 0) return [...items];
    insertAt = anchor + 1;
  }
  return [...rest.slice(0, insertAt), item, ...rest.slice(insertAt)];
}

/** Moves the element at `from` to `to` (same semantics as dnd-kit's arrayMove). */
export function arrayMove<T>(list: readonly T[], from: number, to: number): T[] {
  const out = [...list];
  const [moved] = out.splice(from, 1);
  if (moved !== undefined) out.splice(to, 0, moved);
  return out;
}

/**
 * Drag and drop (owner 2026-11-09): the p_after_id for dropping `activeId` on `overId`'s place.
 * Mirrors reorder_queue_item: an item stays inside its RUSH / normal partition (a normal item can
 * never go above a RUSH one, a RUSH item never below a normal one), so a drop on the other
 * partition is refused (undefined). Undefined too for "no move" or unknown ids; null = top.
 * In-progress items may move (the server allows any open item).
 */
export function dropAfterId<T extends Orderable>(
  items: readonly T[],
  activeId: string,
  overId: string | null | undefined,
): string | null | undefined {
  if (!overId || overId === activeId) return undefined;
  const from = items.findIndex((i) => i.id === activeId);
  const to = items.findIndex((i) => i.id === overId);
  if (from < 0 || to < 0) return undefined;
  const item = items[from];
  if (!item || items[to]?.is_rush !== item.is_rush) return undefined;
  const moved = arrayMove(items, from, to);
  const prev = moved[to - 1];
  return prev && prev.is_rush === item.is_rush ? prev.id : null;
}

/** Same partition as `id`? (Used to keep drag targets inside the RUSH / normal partition.) */
export function samePartition<T extends Orderable>(
  items: readonly T[],
  a: string,
  b: string,
): boolean {
  const x = items.find((i) => i.id === a);
  const y = items.find((i) => i.id === b);
  return !!x && !!y && x.is_rush === y.is_rush;
}

/** "Move to top": null (top of its partition), or undefined when it is already first. */
export function topAfterId<T extends Orderable>(items: readonly T[], id: string): null | undefined {
  const item = items.find((i) => i.id === id);
  if (!item) return undefined;
  const first = items.find((i) => i.is_rush === item.is_rush);
  return first && first.id !== id ? null : undefined;
}

/** The board places (1-based) an item can be moved to: its partition's first and last place. */
export function placeRange<T extends Orderable>(
  items: readonly T[],
  id: string,
): { first: number; last: number } | null {
  const item = items.find((i) => i.id === id);
  if (!item) return null;
  const first = items.findIndex((i) => i.is_rush === item.is_rush);
  const count = items.filter((i) => i.is_rush === item.is_rush).length;
  return { first: first + 1, last: first + count };
}

/**
 * "Move to position…": the p_after_id that puts `id` at board place `place` (1-based), clamped to
 * its partition (a normal item asked for #1 goes to the first normal place). Undefined when the
 * item is already there, the id is unknown or the place is not a whole number.
 */
export function placeAfterId<T extends Orderable>(
  items: readonly T[],
  id: string,
  place: number,
): string | null | undefined {
  const range = placeRange(items, id);
  if (!range || !Number.isInteger(place)) return undefined;
  const target = Math.min(Math.max(place, range.first), range.last) - 1;
  const from = items.findIndex((i) => i.id === id);
  if (target === from) return undefined;
  const moved = arrayMove(items, from, target);
  return target === range.first - 1 ? null : (moved[target - 1]?.id ?? null);
}

/**
 * "Added by NAME" only when someone other than the viewer added the item (owner 2026-11-09: on an
 * owner-only queue his own name on every card is noise). Names reach owners only (get_queue).
 */
export function addedByToShow(
  createdByName: string | null | undefined,
  myName: string | null | undefined,
): string | null {
  const name = createdByName?.trim();
  if (!name) return null;
  const me = myName?.trim();
  return me && me.localeCompare(name, undefined, { sensitivity: 'accent' }) === 0 ? null : name;
}

/** 1-based place of each item in the board (RUSH first), for "1.", "2.", … */
export function placeNumbers<T extends Orderable>(items: readonly T[]): Map<string, number> {
  return new Map(items.map((i, n) => [i.id, n + 1]));
}

/**
 * Parses a typed load count ("2", "1.5", "1,5"): 0.01–100,000 with at most 2 decimals, mirroring
 * the server's app.check_qty. Returns null when invalid. The server re-validates.
 */
export function parseLoads(input: string): number | null {
  const s = input.trim().replace(',', '.');
  if (!/^\d+(\.\d{1,2})?$/.test(s)) return null;
  const n = Number(s);
  return n >= 0.01 && n <= 100000 ? n : null;
}

/**
 * The open items no washer is pinned to, in board order, for the board's single "Next in queue"
 * panel (each appears once; get_washroom_board repeats the same one on every free washer).
 */
export function nextUnassigned<T extends Orderable & { assigned_machine_id: string | null }>(
  items: readonly T[],
  limit: number,
): { shown: T[]; more: number } {
  const free = items.filter((i) => i.assigned_machine_id === null);
  return { shown: free.slice(0, limit), more: Math.max(0, free.length - limit) };
}
