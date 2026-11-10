-- Audit 2026-11-10: managers could void or back-date finished goods outside the current shift.
-- Owner rule 2026-11-05 ("Managers: current shift totals only, NOT the previous shift"; fge_select since
-- 20261106022557) now also holds for the two finished-goods writes:
-- * app.fg_manager_window_ok(area, shift_instance, occurred_at): true when the entry's shift instance is
--   the area's CURRENT instance or the NEXT one, both resolved with app.clock_entry_shift (the helper
--   record_finished_goods uses to attribute an entry: own = the area's instance at now(), next = the first
--   non-skipped instance starting at/after its end). An off-shift entry (no shift instance) passes only
--   while the area is off-shift now AND it occurred after the end of the area's last instance (the current
--   off-shift gap); an area that never had a shift instance has no gap start.
-- * record_finished_goods: a MANAGER's entry must pass the window (checked after the shift is resolved,
--   so an offline entry for the shift that is running, or 'next', still saves); else NOT_AUTHORIZED. The
--   owner keeps the full 30-day back-dating. Idempotent retries return before the check (unchanged order).
-- * void_finished_goods: a MANAGER may void only an entry that passes the window; older entries are owner
--   only (NOT_AUTHORIZED, checked right after the role check, before the already-voided answer, so a
--   manager learns nothing about entries outside the current shift). Owner unchanged.
-- Same signatures, contracts and grants otherwise.

create function app.fg_manager_window_ok(p_area_id uuid, p_shift_instance_id uuid, p_occurred_at timestamptz)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_now  timestamptz := pg_catalog.now();
  v_cur  uuid;
  v_next uuid;
  v_gap  timestamptz;
begin
  if p_area_id is null then
    return false;
  end if;
  v_cur := app.clock_entry_shift('own', v_now, p_area_id);
  v_next := app.clock_entry_shift('next', v_now, p_area_id);
  if p_shift_instance_id is not null then
    return coalesce(p_shift_instance_id = v_cur, false) or coalesce(p_shift_instance_id = v_next, false);
  end if;
  if v_cur is not null or p_occurred_at is null then
    return false;                                   -- on shift now: an off-shift row is not the current shift
  end if;
  select max(si.ends_at) into v_gap from public.shift_instances si
   where si.area_id = p_area_id and si.skipped_at is null and si.ends_at <= v_now;
  return p_occurred_at >= coalesce(v_gap, '-infinity'::timestamptz);
end;
$$;
comment on function app.fg_manager_window_ok(uuid, uuid, timestamptz) is
  'Audit 2026-11-10 (owner rule 2026-11-05: managers work in the current shift only): true when a finished-goods entry with this area / shift instance / occurred_at is in the manager window: its shift instance is the area''s current one or the next one (app.clock_entry_shift own / next at now()); an off-shift entry (null shift) only while the area is off-shift now and occurred_at ≥ the end of the area''s last non-skipped instance (no lower bound when the area never had one). Internal.';
revoke all on function app.fg_manager_window_ok(uuid, uuid, timestamptz) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.record_finished_goods(p_item_type_id uuid, p_packs integer, p_loose_pieces integer, p_client_id uuid, p_staff_session_id uuid DEFAULT NULL::uuid, p_pack_size_used integer DEFAULT NULL::integer, p_shift_choice text DEFAULT 'own'::text, p_area_id uuid DEFAULT NULL::uuid, p_station_id uuid DEFAULT NULL::uuid, p_queue_item_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text, p_occurred_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS public.finished_goods_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_i      record;
  v_area   uuid;
  v_id     uuid;
  v_plant  uuid;
  v_size   int;
  v_note   text;
  v_choice text;
  v_at     timestamptz;
  v_staff  uuid;
  v_shift  uuid;
  v_n      int;
begin
  select i.id, i.org_id, i.plant_id, i.active, i.count_mode, i.pack_size, i.washed into v_i
    from public.item_types i where i.id = p_item_type_id;
  if v_i.id is null or not app.has_role(v_i.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'record_finished_goods requires owner or manager on the item''s plant';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  select f.id, f.plant_id into v_id, v_plant from public.finished_goods_entries f where f.client_id = p_client_id;
  if v_id is not null then
    if v_plant = v_i.plant_id then
      return app.finished_goods_result(v_id, true);
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  if not v_i.active then
    raise exception 'VALIDATION_FAILED' using detail = 'item_type_id: the item is inactive';
  end if;
  if not v_i.washed then
    raise exception 'VALIDATION_FAILED' using detail = 'item_type_id: this item is never washed (e.g. soil bags), so it is not finished goods';
  end if;

  -- Area: the given one (any active non-washroom area of the plant), else the plant's only active
  -- finishing area.
  if p_area_id is not null then
    select a.id into v_area from public.areas a
     where a.id = p_area_id and a.plant_id = v_i.plant_id and a.active and a.kind <> 'washroom';
  else
    select count(*)::int into v_n from public.areas a where a.plant_id = v_i.plant_id and a.active and a.kind = 'finishing';
    if v_n = 1 then
      select a.id into v_area from public.areas a where a.plant_id = v_i.plant_id and a.active and a.kind = 'finishing';
    end if;
  end if;
  if v_area is null then
    raise exception 'VALIDATION_FAILED' using detail = 'area_id: an active finishing area of the plant is required';
  end if;
  if p_station_id is not null and not exists (
       select 1 from public.stations s where s.id = p_station_id and s.plant_id = v_i.plant_id and s.area_id = v_area and s.active) then
    raise exception 'VALIDATION_FAILED' using detail = 'station_id: not an active station of this area';
  end if;
  if p_queue_item_id is not null and not exists (
       select 1 from public.queue_items q where q.id = p_queue_item_id and q.plant_id = v_i.plant_id) then
    raise exception 'VALIDATION_FAILED' using detail = 'queue_item_id: not a queue item of this plant';
  end if;

  -- Counts (§4.9): integers; packs 0–10,000; loose 0–100,000; at least one > 0.
  if p_packs is null or p_loose_pieces is null or p_packs not between 0 and 10000
     or p_loose_pieces not between 0 and 100000 or p_packs + p_loose_pieces = 0 then
    raise exception 'VALIDATION_FAILED' using detail = 'packs 0–10,000 and loose_pieces 0–100,000, at least one > 0';
  end if;
  if p_pack_size_used is not null and p_pack_size_used not between 1 and 10000 then
    raise exception 'VALIDATION_FAILED' using detail = 'pack_size_used: 1–10,000';
  end if;
  if v_i.count_mode = 'unit' then
    if p_packs <> 0 or p_pack_size_used is not null then
      raise exception 'COUNT_MODE_MISMATCH' using detail = 'unit-counted item: loose_pieces only';
    end if;
  else
    v_size := coalesce(p_pack_size_used, v_i.pack_size);   -- per-entry override, else the item's size
    if p_packs > 0 and v_size is null then
      raise exception 'CONVERSION_MISSING' using detail = 'pack item has no pack_size';
    end if;
  end if;

  v_at := coalesce(p_occurred_at, pg_catalog.now());
  if v_at > pg_catalog.now() + interval '5 minutes' or v_at < pg_catalog.now() - interval '30 days' then
    raise exception 'OUT_OF_RANGE_TIMESTAMP' using detail = 'occurred_at: from 30 days ago to 5 minutes ahead';
  end if;
  v_choice := case coalesce(p_shift_choice, 'own') when 'my' then 'own' else coalesce(p_shift_choice, 'own') end;
  if v_choice not in ('own', 'next') then
    raise exception 'VALIDATION_FAILED' using detail = 'shift_choice: own (my) or next';
  end if;
  v_note := app.clean_note(p_note, 140, 'note');

  -- 2026-11-07: no entry PIN. The signed-in account is the attribution (entered_by); staff_id stays null
  -- and p_staff_session_id is ignored. The shift is the area's shift at occurred_at (own) or the next one.
  v_staff := null;
  v_shift := app.clock_entry_shift(v_choice, v_at, v_area);
  if v_choice = 'next' and v_shift is null then
    raise exception 'VALIDATION_FAILED' using detail = 'shift_choice next: no next shift in this area';
  end if;
  -- Audit 2026-11-10 (owner rule 2026-11-05): a manager enters only into the current or next shift of the
  -- area; anything older (back-dated into a past shift) is the owner's.
  if not app.has_role(v_i.plant_id, '{owner}') and not app.fg_manager_window_ok(v_area, v_shift, v_at) then
    raise exception 'NOT_AUTHORIZED' using detail = 'record_finished_goods: managers enter only in the current or next shift of the area; older entries are owner-only';
  end if;

  insert into public.finished_goods_entries as f (org_id, plant_id, area_id, station_id, shift_instance_id, item_type_id,
                                                   queue_item_id, packs, pack_size_used, loose_pieces, occurred_at, note,
                                                   source, entered_by, staff_id, client_id)
  values (v_i.org_id, v_i.plant_id, v_area, p_station_id, v_shift, v_i.id, p_queue_item_id, p_packs, v_size,
          p_loose_pieces, v_at, v_note, 'manual', (select auth.uid()), v_staff, p_client_id)
  on conflict (client_id) do nothing
  returning f.id into v_id;
  if v_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';   -- concurrent retry; the client refetches
  end if;
  return app.finished_goods_result(v_id, false);
end;
$function$;

comment on function public.record_finished_goods(uuid, integer, integer, uuid, uuid, integer, text, uuid, uuid, uuid, text, timestamptz) is
  'E1 RPC (owner/manager; no entry PIN since 2026-11-07: entered_by = the account, staff_id null, p_staff_session_id ignored): records finished goods. Unit items: p_packs 0 + p_loose_pieces; pack items: packs × pack_size_used (p_pack_size_used override, else the item''s pack_size) + loose; pieces is generated. p_shift_choice own|my|next: the area''s shift at p_occurred_at, or the next one (app.clock_entry_shift; null shift = off-shift, dated by production_date). p_area_id defaults to the plant''s only active finishing area. p_occurred_at default now, allowed 30 days back to 5 min ahead (audited). Audit 2026-11-10 (owner rule 2026-11-05): a MANAGER''s entry must land in the area''s current or next shift instance (or the current off-shift gap; app.fg_manager_window_ok), else NOT_AUTHORIZED; back-dating into older shifts is owner-only. warning LOOSE_EXCEEDS_PACK when loose ≥ pack size. Idempotent on p_client_id (duplicate=true). Items with washed = false (soil bags) are refused with VALIDATION_FAILED. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, COUNT_MODE_MISMATCH, CONVERSION_MISSING, OUT_OF_RANGE_TIMESTAMP.';

create or replace function public.void_finished_goods(p_id uuid, p_reason text)
returns public.finished_goods_result language plpgsql volatile security definer set search_path = '' as $$
declare
  v_f      record;
  v_reason text;
begin
  select f.id, f.plant_id, f.area_id, f.shift_instance_id, f.occurred_at, f.voided_at into v_f
    from public.finished_goods_entries f where f.id = p_id;
  if v_f.id is null or not app.has_role(v_f.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'void_finished_goods requires owner or manager on the entry''s plant';
  end if;
  -- Audit 2026-11-10 (owner rule 2026-11-05): managers void only entries of the area's current or next
  -- shift; older entries are owner-only. Before the already-voided answer: no oracle on older rows.
  if not app.has_role(v_f.plant_id, '{owner}') and not app.fg_manager_window_ok(v_f.area_id, v_f.shift_instance_id, v_f.occurred_at) then
    raise exception 'NOT_AUTHORIZED' using detail = 'void_finished_goods: managers void only entries of the current or next shift; older entries are owner-only';
  end if;
  if v_f.voided_at is not null then
    return app.finished_goods_result(v_f.id, true);
  end if;
  v_reason := app.clean_note(p_reason, 200, 'reason');
  if v_reason is null then
    raise exception 'VALIDATION_FAILED' using detail = 'reason: required (1–200 characters)';
  end if;
  update public.finished_goods_entries f
     set voided_at = pg_catalog.now(), voided_by = (select auth.uid()), void_reason = v_reason
   where f.id = v_f.id and f.voided_at is null;
  return app.finished_goods_result(v_f.id, not found);
end;
$$;
comment on function public.void_finished_goods(uuid, text) is
  'E4 RPC (owner/manager): voids a finished-goods entry with a reason (1–200 chars); voided entries leave every total but stay visible (never deleted). Audited as finished_goods_entries.void. Audit 2026-11-10 (owner rule 2026-11-05): a MANAGER may void only an entry of the area''s current or next shift instance (or of the current off-shift gap; app.fg_manager_window_ok), else NOT_AUTHORIZED (checked before the already-voided answer); older entries are owner-only. Already voided → returns it (duplicate=true). A replacement is a new record_finished_goods call. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
