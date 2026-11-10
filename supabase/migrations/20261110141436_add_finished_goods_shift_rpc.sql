-- Finished-goods entry screen (owner 2026-11-10): finishing managers log output continuously through the
-- shift on a tablet. The screen reads its shift and its running entries through ONE definer RPC:
--
--   public.get_finished_goods_shift(p_area_id uuid) returns jsonb
--
-- * Callers: owner, manager or lead of the area's plant (role check first; an unknown area, a viewer, a
--   display, another tenant → NOT_AUTHORIZED, same answer so nothing leaks). A washroom area →
--   VALIDATION_FAILED (finished goods are entered in finishing / other areas only, as record_finished_goods).
-- * Shift: the area's CURRENT instance (app.shift_instance_at(area, now()): not skipped, starts_at ≤ now <
--   ends_at) with is_current = true. Off shift: the most recent non-skipped instance that has ended
--   (ends_at ≤ now) with is_current = false, so the end-of-shift review still has its header; null when the
--   area never had one.
-- * Entries: the shift instance's NON-VOIDED entries of this area, ordered by occurred_at, created_at, id;
--   plus per-item totals (pieces summed from the generated column, entry count). entered_by / staff_id /
--   voided_by / note are never returned (no names, no per-person data).
-- * Owner rule 2026-11-05 ("Managers: current shift totals only, NOT the previous shift"; fge_select,
--   get_shift_report): when is_current = false, only the OWNER gets the ended shift's entries and totals.
--   A manager or lead gets the header with entries = [] and totals = [] and entries_hidden = true. Showing
--   the just-ended shift to managers for the end-of-shift review needs an owner decision (escalated
--   2026-11-10); it is not done here.
-- * Entries a manager records in the off-shift gap (shift_instance_id null) belong to no instance and are not
--   returned (off-shift output is reported by production_date).

create function public.get_finished_goods_shift(p_area_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_area    record;
  v_now     timestamptz := pg_catalog.now();
  v_si      record;
  v_current boolean := false;
  v_show    boolean;
  v_entries jsonb := '[]'::jsonb;
  v_totals  jsonb := '[]'::jsonb;
  v_shift   jsonb;
begin
  select a.id, a.plant_id, a.kind into v_area from public.areas a where a.id = p_area_id;
  if v_area.id is null or not app.has_role(v_area.plant_id, '{owner,manager,lead}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_finished_goods_shift requires owner, manager or lead on the area''s plant';
  end if;
  if v_area.kind = 'washroom' then
    raise exception 'VALIDATION_FAILED' using detail = 'area_id: finished goods are entered outside the washroom';
  end if;

  select si.id, si.starts_at, si.ends_at, si.production_date, s.name into v_si
    from public.shift_instances si
    join public.shifts s on s.id = si.shift_id
   where si.id = app.shift_instance_at(v_area.id, v_now);
  if v_si.id is not null then
    v_current := true;
  else
    select si.id, si.starts_at, si.ends_at, si.production_date, s.name into v_si
      from public.shift_instances si
      join public.shifts s on s.id = si.shift_id
     where si.area_id = v_area.id and si.skipped_at is null and si.ends_at <= v_now
     order by si.ends_at desc, si.starts_at desc
     limit 1;
  end if;

  -- Owner rule 2026-11-05: only the owner sees a shift that is not running now.
  v_show := v_si.id is not null and (v_current or app.has_role(v_area.plant_id, '{owner}'));

  if v_si.id is not null then
    v_shift := jsonb_build_object('id', v_si.id, 'name', v_si.name, 'starts_at', v_si.starts_at,
                                  'ends_at', v_si.ends_at, 'production_date', v_si.production_date);
  end if;

  if v_show then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', f.id, 'item_type_id', f.item_type_id, 'packs', f.packs, 'pack_size_used', f.pack_size_used,
             'loose_pieces', f.loose_pieces, 'pieces', f.pieces, 'occurred_at', f.occurred_at, 'client_id', f.client_id)
             order by f.occurred_at, f.created_at, f.id), '[]'::jsonb)
      into v_entries
      from public.finished_goods_entries f
     where f.shift_instance_id = v_si.id and f.area_id = v_area.id and f.voided_at is null;

    select coalesce(jsonb_agg(jsonb_build_object('item_type_id', t.item_type_id, 'pieces', t.pieces, 'entries', t.entries)
             order by i.sort_order, i.name), '[]'::jsonb)
      into v_totals
      from (select f.item_type_id, sum(f.pieces)::bigint as pieces, count(*)::int as entries
              from public.finished_goods_entries f
             where f.shift_instance_id = v_si.id and f.area_id = v_area.id and f.voided_at is null
             group by f.item_type_id) t
      join public.item_types i on i.id = t.item_type_id;
  end if;

  return jsonb_build_object(
    'area_id', v_area.id,
    'as_of', v_now,
    'is_current', v_current,
    'entries_hidden', v_si.id is not null and not v_show,
    'shift', v_shift,
    'entries', v_entries,
    'totals', v_totals);
end;
$$;
comment on function public.get_finished_goods_shift(uuid) is
  'E1 entry screen read (owner 2026-11-10; owner, manager or lead of the area''s plant, else NOT_AUTHORIZED; washroom area → VALIDATION_FAILED). Returns jsonb {area_id, as_of, is_current, entries_hidden, shift: {id, name, starts_at, ends_at, production_date} | null, entries: [{id, item_type_id, packs, pack_size_used, loose_pieces, pieces, occurred_at, client_id}] (non-voided, by occurred_at), totals: [{item_type_id, pieces, entries}] (by item sort_order, name)}. shift = the area''s current instance (is_current true), else the most recent ended non-skipped instance (is_current false), else null. Owner rule 2026-11-05: for an ended shift only the OWNER gets entries/totals; a manager or lead gets [] with entries_hidden = true. Never returns entered_by, staff_id, voided_by or notes.';
revoke all on function public.get_finished_goods_shift(uuid) from public, anon, authenticated;
grant execute on function public.get_finished_goods_shift(uuid) to authenticated;
