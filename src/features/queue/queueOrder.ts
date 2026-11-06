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
