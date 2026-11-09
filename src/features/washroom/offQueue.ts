// Off-queue start reasons (owner decision 2026-11-09). A washer start that runs something other than
// what the queue has next for that washer needs a one-tap reason; the server refuses it otherwise
// (OFF_QUEUE_REASON_REQUIRED). Taps stay anonymous: a reason is about the load, never the person.
// Pure module.

export const OFF_QUEUE_REASONS = ['not_ready', 'wrong_washer', 'urgent', 'other'] as const;

export type OffQueueReason = (typeof OFF_QUEUE_REASONS)[number];

export function isOffQueueReason(v: unknown): v is OffQueueReason {
  return typeof v === 'string' && (OFF_QUEUE_REASONS as readonly string[]).includes(v);
}

/**
 * Does a START need a reason first? Only when the person picked a wash group by hand that differs
 * from the queue's next item for this washer. Nothing queued for the washer → no reason (the server
 * agrees); the queue's own next → no reason. If the queue changed since the board was read, the
 * server says so and the tap is kept with a "Pick a reason" action.
 */
export function needsOffQueueReason(
  chosenWashGroupId: string | null | undefined,
  nextQueueItemId: string | null | undefined,
  nextWashGroupId: string | null | undefined,
): boolean {
  if (!chosenWashGroupId || !nextQueueItemId) return false;
  return chosenWashGroupId !== nextWashGroupId;
}
