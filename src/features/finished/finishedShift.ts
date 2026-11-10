// get_finished_goods_shift's jsonb, typed and checked. Pure.

export interface FgShift {
  id: string;
  name: string;
  starts_at: string;
  ends_at: string;
  production_date: string;
}

export interface FgEntry {
  id: string;
  item_type_id: string;
  packs: number;
  pack_size_used: number | null;
  loose_pieces: number;
  pieces: number;
  occurred_at: string;
  client_id: string;
}

export interface FgShiftData {
  area_id: string;
  as_of: string;
  is_current: boolean;
  entries_hidden: boolean;
  shift: FgShift | null;
  entries: FgEntry[];
}

const str = (v: unknown): string | null => (typeof v === 'string' ? v : null);
const num = (v: unknown): number | null =>
  typeof v === 'number' && Number.isFinite(v)
    ? v
    : typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v))
      ? Number(v)
      : null;

/** get_finished_goods_shift's jsonb, checked (unknown shapes become empty, never a crash). */
export function parseFgShift(raw: unknown): FgShiftData | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  const s = o.shift && typeof o.shift === 'object' ? (o.shift as Record<string, unknown>) : null;
  const shift: FgShift | null =
    s && str(s.id) && str(s.starts_at) && str(s.ends_at)
      ? {
          id: str(s.id) as string,
          name: str(s.name) ?? '',
          starts_at: str(s.starts_at) as string,
          ends_at: str(s.ends_at) as string,
          production_date: str(s.production_date) ?? '',
        }
      : null;
  const entries: FgEntry[] = [];
  for (const e of Array.isArray(o.entries) ? o.entries : []) {
    if (!e || typeof e !== 'object') continue;
    const r = e as Record<string, unknown>;
    const id = str(r.id);
    const item = str(r.item_type_id);
    const at = str(r.occurred_at);
    const pieces = num(r.pieces);
    if (!id || !item || !at || pieces === null) continue;
    entries.push({
      id,
      item_type_id: item,
      packs: num(r.packs) ?? 0,
      pack_size_used: num(r.pack_size_used),
      loose_pieces: num(r.loose_pieces) ?? 0,
      pieces,
      occurred_at: at,
      client_id: str(r.client_id) ?? id,
    });
  }
  return {
    area_id: str(o.area_id) ?? '',
    as_of: str(o.as_of) ?? '',
    is_current: o.is_current === true,
    entries_hidden: o.entries_hidden === true,
    shift,
    entries,
  };
}
