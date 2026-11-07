// What a void_customer_delivery result means for the screen (owner 2026-11-07). Pure.
// Queue item ids are mapped to wash groups through what the screen knows: the delivery's own queue
// item ids in line order (record_customer_delivery) or a queue item → group map (owner history).

export interface KeptItem {
  queueItemId: string;
  status: string;
  loadsStarted: number;
}

export interface VoidOutcome {
  deliveryId: string;
  duplicate: boolean;
  /** Wash group ids of the cancelled queue items (null = not known on this phone). */
  cancelled: (string | null)[];
  /** Queue items NOT cancelled (already started or done), with their wash group when known. */
  kept: (KeptItem & { washGroupId: string | null })[];
}

/** kept_items jsonb → typed items; anything unreadable is skipped. */
export function parseKeptItems(value: unknown): KeptItem[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((v): KeptItem[] => {
    if (typeof v !== 'object' || v === null) return [];
    const o = v as Record<string, unknown>;
    if (typeof o.queue_item_id !== 'string') return [];
    const loads = Number(o.loads_started);
    return [
      {
        queueItemId: o.queue_item_id,
        status: typeof o.status === 'string' ? o.status : 'unknown',
        loadsStarted: Number.isFinite(loads) ? loads : 0,
      },
    ];
  });
}

/** queue item id → wash group id, from the delivery's queue item ids and lines (same order). */
export function groupMapFromLines(
  queueItemIds: readonly string[],
  lines: readonly { washGroupId: string }[],
): Map<string, string> {
  const map = new Map<string, string>();
  if (queueItemIds.length !== lines.length) return map;
  queueItemIds.forEach((id, i) => {
    const line = lines[i];
    if (line) map.set(id, line.washGroupId);
  });
  return map;
}

export function describeVoid(
  result: {
    delivery_id: string | null;
    cancelled_item_ids: string[] | null;
    kept_items: unknown;
    duplicate: boolean | null;
  },
  groupOf: ReadonlyMap<string, string>,
): VoidOutcome {
  return {
    deliveryId: result.delivery_id ?? '',
    duplicate: result.duplicate === true,
    cancelled: (result.cancelled_item_ids ?? []).map((id) => groupOf.get(id) ?? null),
    kept: parseKeptItems(result.kept_items).map((k) => ({
      ...k,
      washGroupId: groupOf.get(k.queueItemId) ?? null,
    })),
  };
}

/** The reason as the server will take it: trimmed, 1–200 characters, no control characters. */
export function cleanReason(text: string): string | null {
  const v = text
    // eslint-disable-next-line no-control-regex -- strip control characters from typed text
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return v.length === 0 ? null : v.slice(0, 200);
}
