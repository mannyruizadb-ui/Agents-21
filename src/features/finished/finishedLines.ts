import type { FgShiftData } from './finishedShift';
import type { LogLine } from './finishedLogic';
import type { PendingFinished, SavedFinished } from './finishedOutbox';

// The lines the screen shows for the shift: the server's, plus this device's lines the server list
// doesn't show yet (just saved, or still waiting to send). Optimistic, so a tap shows at once and the
// total never jumps back while the list refetches. Pure.

function inShift(at: string, data: FgShiftData): boolean {
  if (!data.shift || !data.is_current) return false;
  const t = Date.parse(at);
  return t >= Date.parse(data.shift.starts_at) && t < Date.parse(data.shift.ends_at);
}

/** Every line of the shift, oldest first. */
export function mergeLines(
  data: FgShiftData | null | undefined,
  saved: readonly SavedFinished[],
  pending: readonly PendingFinished[],
  areaId: string,
): LogLine[] {
  const lines: LogLine[] = [];
  const voided = new Set(saved.filter((s) => s.voidedAt).map((s) => s.id));
  const seen = new Set<string>();
  for (const e of data?.entries ?? []) {
    seen.add(e.client_id);
    if (voided.has(e.id)) continue;
    lines.push({
      key: e.id,
      itemTypeId: e.item_type_id,
      packs: e.packs,
      loose: e.loose_pieces,
      pieces: e.pieces,
      occurredAt: e.occurred_at,
      id: e.id,
      clientId: e.client_id,
      pending: false,
    });
  }
  if (data && !data.entries_hidden) {
    for (const s of saved) {
      if (s.voidedAt || seen.has(s.clientId) || s.areaId !== areaId) continue;
      if (!inShift(s.occurredAt, data)) continue;
      seen.add(s.clientId);
      lines.push({
        key: s.clientId,
        itemTypeId: s.itemTypeId,
        packs: s.packs,
        loose: s.loose,
        pieces: s.pieces,
        occurredAt: s.occurredAt,
        id: s.id,
        clientId: s.clientId,
        pending: false,
      });
    }
  }
  for (const p of pending) {
    if (seen.has(p.clientId) || p.areaId !== areaId) continue;
    lines.push({
      key: p.clientId,
      itemTypeId: p.itemTypeId,
      packs: p.packs,
      loose: p.loose,
      pieces: p.packs * (p.packSizeUsed ?? 0) + p.loose, // preview until the server's value arrives
      occurredAt: p.enteredAt,
      id: null,
      clientId: p.clientId,
      pending: true,
    });
  }
  return lines.sort((a, b) => Date.parse(a.occurredAt) - Date.parse(b.occurredAt));
}
