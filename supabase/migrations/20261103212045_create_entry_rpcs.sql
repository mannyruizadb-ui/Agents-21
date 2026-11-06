-- M2 pilot write path, part 4: name + PIN entry RPCs (PRD A8, B1, E1, E4; §5.3; ADR 001 option B).
-- Soil estimates and finished goods are owner/manager entries confirmed with an entry-staff session
-- (start_staff_session: name + 4-digit PIN). Washer taps (no PIN) and queue writes are elsewhere.
--
-- Staff session rules (security carry-forward "staff_sessions bound to auth_user_id/plant/expiry/
-- consumed in M2 write RPCs"): the session must belong to the CALLER (auth_user_id), to the row's
-- plant, be unexpired and unconsumed, and its person must still be active. With the plant's
-- staff_pin_reuse_minutes = 0 (default: a PIN on every entry) the session is consumed by the entry;
-- with a reuse window it stays valid until expires_at. Anything else → STAFF_SESSION_REQUIRED.
-- Idempotency is checked BEFORE the session, so an offline retry of an entry that was already saved
-- returns that entry even though its single-use session is spent (PRD E3).

create function app.use_staff_session(p_staff_session_id uuid, p_plant_id uuid)
returns uuid language plpgsql volatile set search_path = '' as $$
declare
  v_s     record;
  v_reuse int;
begin
  select s.id, s.staff_id, s.expires_at, s.consumed_at, es.active
    into v_s
    from public.staff_sessions s
    join public.entry_staff es on es.id = s.staff_id and es.plant_id = s.plant_id
   where s.id = p_staff_session_id
     and s.plant_id = p_plant_id
     and s.auth_user_id = (select auth.uid())
     for update of s;
  if v_s.id is null or v_s.expires_at <= pg_catalog.now() or v_s.consumed_at is not null or not v_s.active then
    raise exception 'STAFF_SESSION_REQUIRED' using detail = 'confirm name + PIN again (session missing, expired, used, or not yours)';
  end if;
  select p.staff_pin_reuse_minutes into v_reuse from public.plants p where p.id = p_plant_id;
  if coalesce(v_reuse, 0) = 0 then
    update public.staff_sessions s set consumed_at = pg_catalog.now() where s.id = v_s.id;
  end if;
  return v_s.staff_id;
end;
$$;
comment on function app.use_staff_session(uuid, uuid) is
  'A8 write-RPC helper: returns the staff_id of a valid staff session (caller''s own, same plant, unexpired, unconsumed, active person) and consumes it when the plant''s staff_pin_reuse_minutes = 0. Else STAFF_SESSION_REQUIRED. Internal (no client EXECUTE).';
revoke all on function app.use_staff_session(uuid, uuid) from public, anon, authenticated;

-- ── record_soil_estimate (B1) ─────────────────────────────────────────────
create function public.record_soil_estimate(
  p_wash_group_id    uuid,
  p_qty              numeric,
  p_unit             app.qty_unit,
  p_client_id        uuid,
  p_staff_session_id uuid,
  p_note             text default null)
returns public.soil_estimates language plpgsql volatile security definer set search_path = '' as $$
declare
  v_g     record;
  v_row   public.soil_estimates;
  v_note  text;
  v_staff uuid;
begin
  select g.id, g.org_id, g.plant_id, g.active, g.allow_basket_estimates into v_g
    from public.wash_groups g where g.id = p_wash_group_id;
  if v_g.id is null or not app.has_role(v_g.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'record_soil_estimate requires owner or manager on the wash group''s plant';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  select e.* into v_row from public.soil_estimates e where e.client_id = p_client_id;
  if v_row.id is not null then
    if v_row.plant_id = v_g.plant_id then
      return v_row;
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  if not v_g.active then
    raise exception 'VALIDATION_FAILED' using detail = 'wash_group_id: the wash group is inactive';
  end if;
  perform app.check_qty(p_qty, 0, 10000, 'qty');
  if p_unit is null or p_unit not in ('load', 'basket') then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: load or basket';
  end if;
  if p_unit = 'basket' and not v_g.allow_basket_estimates then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: basket estimates are not allowed for this wash group';
  end if;
  v_note := app.clean_note(p_note, 280, 'note');
  v_staff := app.use_staff_session(p_staff_session_id, v_g.plant_id);

  insert into public.soil_estimates as e (org_id, plant_id, wash_group_id, qty, unit, note, entered_by, staff_id, client_id)
  values (v_g.org_id, v_g.plant_id, v_g.id, p_qty, p_unit, v_note, (select auth.uid()), v_staff, p_client_id)
  on conflict (client_id) do nothing
  returning e.* into v_row;
  if v_row.id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';   -- concurrent retry; the client refetches
  end if;
  return v_row;
end;
$$;
comment on function public.record_soil_estimate(uuid, numeric, app.qty_unit, uuid, uuid, text) is
  'B1 RPC (owner/manager + staff session, A8): appends a soil estimate for a wash group (never updates; 0 = cleared). qty 0–10,000 (2 decimals) in load, or basket when the group allows it; note ≤ 280. Idempotent on p_client_id (returns the existing row, even after the single-use session is spent). Returns the soil_estimates row. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, STAFF_SESSION_REQUIRED.';
revoke all on function public.record_soil_estimate(uuid, numeric, app.qty_unit, uuid, uuid, text) from public, anon;
grant execute on function public.record_soil_estimate(uuid, numeric, app.qty_unit, uuid, uuid, text) to authenticated, service_role;

-- ── Finished goods (E1, E4) ───────────────────────────────────────────────
create type public.finished_goods_result as (
  id                uuid,
  item_type_id      uuid,
  wash_group_id     uuid,
  area_id           uuid,
  station_id        uuid,
  queue_item_id     uuid,
  packs             int,
  pack_size_used    int,
  loose_pieces      int,
  pieces            int,               -- generated by the database
  occurred_at       timestamptz,
  shift_instance_id uuid,              -- null = off-shift
  production_date   date,
  staff_id          uuid,
  voided_at         timestamptz,
  void_reason       text,
  warning           text,              -- 'LOOSE_EXCEEDS_PACK' or null
  duplicate         boolean            -- true = idempotent retry / already voided
);
comment on type public.finished_goods_result is 'record_finished_goods / void_finished_goods result (PRD §5.3).';

create function app.finished_goods_result(p_id uuid, p_duplicate boolean)
returns public.finished_goods_result language sql stable set search_path = '' as $$
  select f.id, f.item_type_id, f.wash_group_id, f.area_id, f.station_id, f.queue_item_id, f.packs, f.pack_size_used,
         f.loose_pieces, f.pieces, f.occurred_at, f.shift_instance_id, f.production_date, f.staff_id,
         f.voided_at, f.void_reason,
         case when f.pack_size_used is not null and f.loose_pieces >= f.pack_size_used then 'LOOSE_EXCEEDS_PACK' end,
         p_duplicate
    from public.finished_goods_entries f
   where f.id = p_id;
$$;
comment on function app.finished_goods_result(uuid, boolean) is 'Builds public.finished_goods_result (internal).';
revoke all on function app.finished_goods_result(uuid, boolean) from public, anon, authenticated;

create function public.record_finished_goods(
  p_item_type_id     uuid,
  p_packs            int,
  p_loose_pieces     int,
  p_client_id        uuid,
  p_staff_session_id uuid,
  p_pack_size_used   int default null,
  p_shift_choice     text default 'own',
  p_area_id          uuid default null,
  p_station_id       uuid default null,
  p_queue_item_id    uuid default null,
  p_note             text default null,
  p_occurred_at      timestamptz default null)
returns public.finished_goods_result language plpgsql volatile security definer set search_path = '' as $$
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
  select i.id, i.org_id, i.plant_id, i.active, i.count_mode, i.pack_size into v_i
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

  v_staff := app.use_staff_session(p_staff_session_id, v_i.plant_id);
  v_shift := app.resolve_entry_shift(v_staff, v_choice, v_at, v_area);
  if v_choice = 'next' and v_shift is null then
    raise exception 'VALIDATION_FAILED' using detail = 'shift_choice next: no next shift in this area';
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
$$;
comment on function public.record_finished_goods(uuid, int, int, uuid, uuid, int, text, uuid, uuid, uuid, text, timestamptz) is
  'E1 RPC (owner/manager + staff session, A8): records finished goods. Unit items: p_packs 0 + p_loose_pieces; pack items: packs × pack_size_used (p_pack_size_used override, else the item''s pack_size) + loose; pieces is generated. p_shift_choice own|my|next (A8 person-based shift via app.resolve_entry_shift; null shift = off-shift, dated by production_date). p_area_id defaults to the plant''s only active finishing area. p_occurred_at default now, allowed 30 days back to 5 min ahead (audited). warning LOOSE_EXCEEDS_PACK when loose ≥ pack size. Idempotent on p_client_id (duplicate=true). Errors: NOT_AUTHORIZED, VALIDATION_FAILED, COUNT_MODE_MISMATCH, CONVERSION_MISSING, OUT_OF_RANGE_TIMESTAMP, STAFF_SESSION_REQUIRED, RATE_LIMITED.';
revoke all on function public.record_finished_goods(uuid, int, int, uuid, uuid, int, text, uuid, uuid, uuid, text, timestamptz) from public, anon;
grant execute on function public.record_finished_goods(uuid, int, int, uuid, uuid, int, text, uuid, uuid, uuid, text, timestamptz) to authenticated, service_role;

create function public.void_finished_goods(p_id uuid, p_reason text)
returns public.finished_goods_result language plpgsql volatile security definer set search_path = '' as $$
declare
  v_f      record;
  v_reason text;
begin
  select f.id, f.plant_id, f.voided_at into v_f from public.finished_goods_entries f where f.id = p_id;
  if v_f.id is null or not app.has_role(v_f.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'void_finished_goods requires owner or manager on the entry''s plant';
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
  'E4 RPC (owner/manager): voids a finished-goods entry with a reason (1–200 chars); voided entries leave every total but stay visible (never deleted). Audited as finished_goods_entries.void. Already voided → returns it (duplicate=true). A replacement is a new record_finished_goods call. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.void_finished_goods(uuid, text) from public, anon;
grant execute on function public.void_finished_goods(uuid, text) to authenticated, service_role;
