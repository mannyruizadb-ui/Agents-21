-- One sign-in method: entry PINs are no longer required (owner 2026-11-07, "green light").
--
-- record_soil_estimate, record_finished_goods and record_customer_delivery no longer need a staff session
-- (name + 4-digit PIN, PRD A8). The signed-in account is the attribution: entered_by = auth.uid() (as
-- before), staff_id is null on new rows. Signatures are unchanged except that p_staff_session_id now has
-- DEFAULT NULL and is IGNORED, so the deployed app (which still sends a session id) keeps working until the
-- new frontend ships; STAFF_SESSION_REQUIRED is never raised by these three any more.
-- * Finished goods shift: was the entry person's home shift (app.resolve_entry_shift on the staff row);
--   now app.clock_entry_shift: the area's shift instance at occurred_at ('own'), or the next non-skipped
--   instance of the area ('next'); null = off-shift (dated by production_date, as before).
-- * entry_staff / staff_sessions / start_staff_session stay (history rows point at them; nothing is
--   dropped). They are simply no longer required.
-- * Owner-only name reads (app.person_name): the entry-staff name for old PIN rows, else the account's
--   profile name, else its USERNAME (app.login_username); never an email or part of one (was: the email's
--   local part).

create function app.clock_entry_shift(p_choice text, p_ts timestamptz, p_area_id uuid)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare
  v_choice text := coalesce(p_choice, 'own');
  v_base   uuid;
  v_from   timestamptz;
begin
  if p_ts is null or p_area_id is null or v_choice not in ('own', 'next') then
    raise exception 'VALIDATION_FAILED' using detail = 'clock_entry_shift: area and timestamp required; choice own|next';
  end if;
  v_base := app.shift_instance_at(p_area_id, p_ts);
  if v_choice = 'own' then
    return v_base;   -- null = off-shift
  end if;
  select si.ends_at into v_from from public.shift_instances si where si.id = v_base;
  return (select si.id from public.shift_instances si
           where si.area_id = p_area_id and si.skipped_at is null
             and si.starts_at >= coalesce(v_from, p_ts)
           order by si.starts_at
           limit 1);
end;
$$;
comment on function app.clock_entry_shift(text, timestamptz, uuid) is
  '2026-11-07 (no entry PINs): the shift instance an account''s entry belongs to: own = the area''s instance at p_ts (null = off-shift); next = the first non-skipped instance of the area starting at/after the end of that instance (or at/after p_ts when off-shift). Internal.';
revoke all on function app.clock_entry_shift(text, timestamptz, uuid) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.record_soil_estimate(p_wash_group_id uuid, p_qty numeric, p_unit app.qty_unit, p_client_id uuid, p_staff_session_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text, p_entered_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS public.soil_estimates
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_g        record;
  v_row      public.soil_estimates;
  v_note     text;
  v_staff    uuid;
  v_now      timestamptz := pg_catalog.now();
  v_ts       timestamptz;
  v_recorded timestamptz;
begin
  select g.id, g.org_id, g.plant_id, g.active, g.allow_basket_estimates, g.allow_bin_estimates into v_g
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
  -- Offline estimates keep their real time; checked after idempotency, so a late retry of a saved
  -- estimate still returns it.
  v_ts := coalesce(p_entered_at, v_now);
  if v_ts < v_now - interval '6 hours' or v_ts > v_now + interval '1 minute' then
    raise exception 'OUT_OF_RANGE_TIMESTAMP' using detail = 'p_entered_at: must be within the last 6 hours (up to 1 minute ahead)';
  end if;
  if not v_g.active then
    raise exception 'VALIDATION_FAILED' using detail = 'wash_group_id: the wash group is inactive';
  end if;
  perform app.check_qty(p_qty, 0, 10000, 'qty');
  if p_unit is null or p_unit not in ('load', 'basket', 'bin') then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: load, basket or bin';
  end if;
  if p_unit = 'basket' and not v_g.allow_basket_estimates then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: basket estimates are not allowed for this wash group';
  end if;
  if p_unit = 'bin' and not v_g.allow_bin_estimates then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: bin estimates are not allowed for this wash group';
  end if;
  v_note := app.clean_note(p_note, 280, 'note');
  -- 2026-11-07: no entry PIN. The signed-in account is the attribution (entered_by); staff_id stays null
  -- and p_staff_session_id is ignored (kept so the deployed app keeps working).
  v_staff := null;

  -- Owner 2026-11-06 (C), race-free since 2026-11-07 (security review e): the (plant, account) batch lock
  -- is taken BEFORE the insert, and recorded_at is the wall clock under that lock, so recorded_at only
  -- grows per (plant, account) and every estimate is judged against the batches committed before it.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('estimate_alert:' || v_g.plant_id::text || ':' || (select auth.uid())::text, 0));
  v_recorded := pg_catalog.clock_timestamp();

  insert into public.soil_estimates as e (org_id, plant_id, wash_group_id, qty, unit, note, entered_by, staff_id, client_id, entered_at, recorded_at)
  values (v_g.org_id, v_g.plant_id, v_g.id, p_qty, p_unit, v_note, (select auth.uid()), v_staff, p_client_id, v_ts, v_recorded)
  on conflict (client_id) do nothing
  returning e.* into v_row;
  if v_row.id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';   -- concurrent retry; the client refetches
  end if;
  -- A batch = the estimates one account records on this plant within 10 minutes of the batch's FIRST
  -- estimate (its recorded_at; the alert's sent_at for rows recorded before recorded_at existed).
  if not exists (select 1 from public.alert_events a
                   join public.soil_estimates s on s.id = a.subject_id and s.plant_id = a.plant_id
                  where a.kind = 'estimate_entered' and a.plant_id = v_g.plant_id
                    and s.entered_by = (select auth.uid())
                    and coalesce(s.recorded_at, a.sent_at) > v_recorded - interval '10 minutes') then
    perform app.raise_owner_alert(v_g.org_id, v_g.plant_id, 'estimate_entered', v_row.id);
  end if;
  return v_row;
end;
$function$;

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

CREATE OR REPLACE FUNCTION public.record_customer_delivery(p_plant_id uuid, p_customer_id uuid, p_lines jsonb, p_client_id uuid, p_staff_session_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text, p_entered_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS public.customer_delivery_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_plant    record;
  v_existing uuid;
  v_now      timestamptz := pg_catalog.now();
  v_ts       timestamptz;
  v_line     record;
  v_group    uuid;
  v_bins     numeric;
  v_groups   uuid[] := '{}';
  v_bins_all numeric[] := '{}';
  v_area     uuid;
  v_areas    int;
  v_note     text;
  v_staff    uuid;
  v_del      uuid;
  v_q        uuid;
  v_recent   int;
begin
  -- Role check FIRST: a missing plant and another tenant's plant give the same answer.
  select p.id, p.org_id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant.id is null or not app.has_role(v_plant.id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'record_customer_delivery requires owner or manager on the plant';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  -- Idempotency (per plant) before the time window and the throttle: an offline retry
  -- returns the saved delivery. Another plant's client_id is invisible here (security review c).
  select d.id into v_existing from public.customer_deliveries d
   where d.plant_id = v_plant.id and d.client_id = p_client_id;
  if v_existing is not null then
    return app.customer_delivery_result(v_existing, true);
  end if;
  v_ts := coalesce(p_entered_at, v_now);
  if v_ts < v_now - interval '6 hours' or v_ts > v_now + interval '1 minute' then
    raise exception 'OUT_OF_RANGE_TIMESTAMP' using detail = 'p_entered_at: must be within the last 6 hours (up to 1 minute ahead)';
  end if;
  if p_customer_id is null or not exists (select 1 from public.customers c
                                           where c.id = p_customer_id and c.plant_id = v_plant.id and c.active) then
    raise exception 'VALIDATION_FAILED' using detail = 'customer_id: no active customer with this id in the plant';
  end if;
  if p_lines is null or pg_catalog.jsonb_typeof(p_lines) <> 'array'
     or pg_catalog.jsonb_array_length(p_lines) not between 1 and 30 then
    raise exception 'VALIDATION_FAILED' using detail = 'p_lines: an array of 1–30 {wash_group_id, bins}';
  end if;
  for v_line in select e.val, e.ord from pg_catalog.jsonb_array_elements(p_lines) with ordinality e(val, ord) loop
    if pg_catalog.jsonb_typeof(v_line.val) <> 'object'
       or exists (select 1 from pg_catalog.jsonb_object_keys(v_line.val) k where k not in ('wash_group_id', 'bins'))
       or pg_catalog.jsonb_typeof(v_line.val -> 'wash_group_id') is distinct from 'string'
       or (v_line.val ->> 'wash_group_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or pg_catalog.jsonb_typeof(v_line.val -> 'bins') is distinct from 'number' then
      raise exception 'VALIDATION_FAILED' using detail = format('p_lines[%s]: {wash_group_id: uuid, bins: number}', v_line.ord);
    end if;
    v_group := (v_line.val ->> 'wash_group_id')::uuid;
    v_bins := (v_line.val ->> 'bins')::numeric;
    if v_bins < 0.25 or v_bins > 50 or v_bins * 4 <> pg_catalog.trunc(v_bins * 4) then
      raise exception 'VALIDATION_FAILED' using detail = format('p_lines[%s].bins: 0.25–50 in quarters', v_line.ord);
    end if;
    if not exists (select 1 from public.wash_groups g
                    where g.id = v_group and g.plant_id = v_plant.id and g.active and g.customer_id = p_customer_id) then
      raise exception 'VALIDATION_FAILED' using detail = format('p_lines[%s].wash_group_id: not an active wash group of this customer', v_line.ord);
    end if;
    if v_group = any (v_groups) then
      raise exception 'VALIDATION_FAILED' using detail = format('p_lines[%s].wash_group_id: listed twice', v_line.ord);
    end if;
    v_groups := v_groups || v_group;
    v_bins_all := v_bins_all || v_bins;
  end loop;
  select count(*), min(a.id::text)::uuid into v_areas, v_area
    from public.areas a where a.plant_id = v_plant.id and a.kind = 'washroom' and a.active;
  if v_areas <> 1 then
    raise exception 'VALIDATION_FAILED' using detail = 'the plant needs exactly one active washroom area for deliveries';
  end if;
  v_note := app.clean_note(p_note, 200, 'note');
  -- 2026-11-07: no entry PIN (entered_by = the account; staff_id null; p_staff_session_id ignored).
  v_staff := null;

  -- Serialize with the queue RPCs and the washer taps of the area (positions); also makes the throttle
  -- count race-free (every delivery of the plant passes this lock).
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('queue:' || v_area::text, 0));
  -- A concurrent retry may have saved it while this call waited for the lock.
  select d.id into v_existing from public.customer_deliveries d
   where d.plant_id = v_plant.id and d.client_id = p_client_id;
  if v_existing is not null then
    return app.customer_delivery_result(v_existing, true);
  end if;
  -- b. Throttle: at most 10 new deliveries per plant per account in any 10 minutes.
  select count(*) into v_recent from public.customer_deliveries d
   where d.plant_id = v_plant.id and d.entered_by = (select auth.uid())
     and d.created_at > pg_catalog.now() - interval '10 minutes';
  if v_recent >= 10 then
    raise exception 'RATE_LIMITED' using detail = 'at most 10 deliveries per plant per account in 10 minutes';
  end if;

  insert into public.customer_deliveries as d (org_id, plant_id, customer_id, delivered_at, entered_by, staff_id, client_id, note)
  values (v_plant.org_id, v_plant.id, p_customer_id, v_ts, (select auth.uid()), v_staff, p_client_id, v_note)
  on conflict (plant_id, client_id) do nothing
  returning d.id into v_del;
  if v_del is null then   -- unreachable under the lock; kept as a guard
    select d.id into v_del from public.customer_deliveries d where d.client_id = p_client_id and d.plant_id = v_plant.id;
    return app.customer_delivery_result(v_del, true);
  end if;

  for i in 1 .. pg_catalog.cardinality(v_groups) loop
    -- Normal (not rush, not rewash) work at the bottom of the normal items; customer_id by trigger.
    insert into public.queue_items as q (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position,
                                         is_rush, note, created_by, client_id, assigned_machine_id, is_rewash)
    values (v_plant.org_id, v_plant.id, v_area, v_groups[i], null, v_bins_all[i], 'bin',
            app.queue_edge_position(v_area, false, false, null),
            false, null, (select auth.uid()), gen_random_uuid(), null, false)
    returning q.id into v_q;
    insert into public.customer_delivery_lines (org_id, plant_id, delivery_id, line_no, wash_group_id, bins, queue_item_id)
    values (v_plant.org_id, v_plant.id, v_del, i, v_groups[i], v_bins_all[i], v_q);
  end loop;

  perform app.raise_owner_alert(v_plant.org_id, v_plant.id, 'customer_delivery', v_del);
  return app.customer_delivery_result(v_del, false);
end;
$function$;

comment on function public.record_soil_estimate(uuid, numeric, app.qty_unit, uuid, uuid, text, timestamptz) is
  'B1 RPC (owner/manager; no entry PIN since 2026-11-07: entered_by = the account, staff_id null, p_staff_session_id ignored): appends a soil estimate for a wash group (never updates; 0 = cleared). qty 0–10,000 (2 decimals; e.g. 2.75 bins) in load, or basket / bin when the group allows it; note ≤ 280; p_entered_at = the device time of an offline entry (default now; within [now − 6 h, now + 1 min], else OUT_OF_RANGE_TIMESTAMP). Owner 2026-11-06: the first estimate of an entry batch (one account, one plant, 10 minutes from the batch''s first recorded_at) writes an estimate_entered owner alert; the batch lock is taken before the insert and recorded_at = clock_timestamp() under it (2026-11-07), so a racing estimate is always in its batch. Idempotent on p_client_id, checked before the time window (returns the existing row; no second alert). Returns the soil_estimates row. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, OUT_OF_RANGE_TIMESTAMP.';
comment on function public.record_finished_goods(uuid, integer, integer, uuid, uuid, integer, text, uuid, uuid, uuid, text, timestamptz) is
  'E1 RPC (owner/manager; no entry PIN since 2026-11-07: entered_by = the account, staff_id null, p_staff_session_id ignored): records finished goods. Unit items: p_packs 0 + p_loose_pieces; pack items: packs × pack_size_used (p_pack_size_used override, else the item''s pack_size) + loose; pieces is generated. p_shift_choice own|my|next: the area''s shift at p_occurred_at, or the next one (app.clock_entry_shift; null shift = off-shift, dated by production_date). p_area_id defaults to the plant''s only active finishing area. p_occurred_at default now, allowed 30 days back to 5 min ahead (audited). warning LOOSE_EXCEEDS_PACK when loose ≥ pack size. Idempotent on p_client_id (duplicate=true). Items with washed = false (soil bags) are refused with VALIDATION_FAILED. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, COUNT_MODE_MISMATCH, CONVERSION_MISSING, OUT_OF_RANGE_TIMESTAMP.';
comment on function public.record_customer_delivery(uuid, uuid, jsonb, uuid, uuid, text, timestamptz) is
  'Owner 2026-11-06 (B) RPC (owner or manager of the plant; no entry PIN since 2026-11-07: entered_by = the account, staff_id null, p_staff_session_id ignored; definer, role check first, no oracle): records an outside customer''s delivery. p_lines: 1–30 {wash_group_id, bins}: active wash groups of p_customer_id (an active customer of the plant), each once, bins 0.25–50 in quarters. p_note ≤ 200. p_entered_at = delivered_at (device time of an offline entry; default now; within [now − 6 h, now + 1 min], else OUT_OF_RANGE_TIMESTAMP). Throttle (security review 2026-11-07): at most 10 new deliveries per plant per account in 10 minutes, else RATE_LIMITED (counted under the queue lock; retries never count). Writes customer_deliveries + customer_delivery_lines (loads = app.to_loads, null without loads_per_bin) and, per line, one washroom queue item at the BOTTOM of the normal items (unit bin, qty = bins, not rush, not rewash, not assigned, customer_id = the customer), then a customer_delivery owner alert. Idempotent on (plant, p_client_id), checked before the time window and the throttle (duplicate = true); a client_id used on another plant is independent (no cross-tenant answer). Void with void_customer_delivery. Returns customer_delivery_result {delivery_id, queue_item_ids (line order), duplicate}. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, OUT_OF_RANGE_TIMESTAMP, RATE_LIMITED.';

-- ── Owner-only names: account name without the email ──────────────────────
create or replace function app.person_name(p_user uuid, p_staff uuid, p_plant uuid)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select s.display_name from public.entry_staff s where s.id = p_staff and s.plant_id = p_plant),
    (select coalesce(nullif(pg_catalog.btrim(pr.full_name), ''), app.login_username(u.email))
       from auth.users u left join public.profiles pr on pr.user_id = u.id
      where u.id = p_user));
$$;
comment on function app.person_name(uuid, uuid, uuid) is
  'Owner 2026-11-06 (D), updated 2026-11-07 (no entry PINs): the name shown to OWNERS for who entered a row: the entry-staff display name for old PIN-attributed rows (staff_id, same plant), else the account''s profile full_name, else its username (app.login_username; null for an unmapped email: an email is never shown). Internal (owner-only reads).';
