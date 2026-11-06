-- Batch review 2026-11-06 (PASS WITH NOTES), notes 2, 3, 5 and 6 (note 4, the task timing window,
-- waits on the owner):
-- (2) record_finished_goods refuses items that are never washed (washed = false, e.g. soil bags) with
--     VALIDATION_FAILED instead of a raw not-null error.
-- (3) app.audit() also strips done_by (tasks) from the before/after images.
-- (5) route_loaded alerts: at most one per route and load date per 10 minutes (like machine_down).
-- (6) mark_route_loaded requires an active route.

CREATE OR REPLACE FUNCTION public.record_finished_goods(p_item_type_id uuid, p_packs integer, p_loose_pieces integer, p_client_id uuid, p_staff_session_id uuid, p_pack_size_used integer DEFAULT NULL::integer, p_shift_choice text DEFAULT 'own'::text, p_area_id uuid DEFAULT NULL::uuid, p_station_id uuid DEFAULT NULL::uuid, p_queue_item_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text, p_occurred_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
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
$function$;
comment on function public.record_finished_goods(uuid, integer, integer, uuid, uuid, integer, text, uuid, uuid, uuid, text, timestamptz) is
  'E1 RPC (owner/manager + staff session, A8): records finished goods. Unit items: p_packs 0 + p_loose_pieces; pack items: packs × pack_size_used (p_pack_size_used override, else the item''s pack_size) + loose; pieces is generated. p_shift_choice own|my|next (A8 person-based shift via app.resolve_entry_shift; null shift = off-shift, dated by production_date). p_area_id defaults to the plant''s only active finishing area. p_occurred_at default now, allowed 30 days back to 5 min ahead (audited). warning LOOSE_EXCEEDS_PACK when loose ≥ pack size. Idempotent on p_client_id (duplicate=true). Errors: NOT_AUTHORIZED, VALIDATION_FAILED, COUNT_MODE_MISMATCH, CONVERSION_MISSING, OUT_OF_RANGE_TIMESTAMP, STAFF_SESSION_REQUIRED, RATE_LIMITED. Items with washed = false (soil bags) are refused with VALIDATION_FAILED (batch review 2026-11-06).';

CREATE OR REPLACE FUNCTION app.audit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_before jsonb;
  v_after  jsonb;
  v_org    uuid;
  v_plant  uuid;
  v_action text := tg_table_name || '.' || lower(tg_op);
  v_device uuid;
begin
  -- Columns are read through jsonb so this one function works on tables without them.
  -- Security L1: pin_hash and the lockout counters are never written to audit_log.
  v_after := to_jsonb(new) - 'pin_hash' - 'failed_pin_attempts' - 'locked_until';
  if tg_op = 'UPDATE' then
    v_before := to_jsonb(old) - 'pin_hash' - 'failed_pin_attempts' - 'locked_until';
    if tg_table_name = 'entry_staff'
       and (to_jsonb(old) ->> 'pin_hash') is distinct from (to_jsonb(new) ->> 'pin_hash') then
      v_action := 'entry_staff.pin_set';
    elsif v_before = v_after then
      return null;  -- no-op update
    elsif tg_table_name = 'entry_staff' and (v_before - 'updated_at') = (v_after - 'updated_at') then
      return null;  -- D12: lockout-counter-only update
    end if;
    if tg_table_name = 'finished_goods_entries'
       and v_before ->> 'voided_at' is null and v_after ->> 'voided_at' is not null then
      v_action := 'finished_goods_entries.void';
    end if;
  end if;

  -- Security review H1 (2026-11-04): push subscription keys and endpoints never reach audit_log
  -- (owners/managers read it). Keep only the push service host. On a rebind to another org, the
  -- previous org's ids are dropped from "before" so they are not shown to the new org.
  if tg_table_name = 'push_subscriptions' then
    v_after := (v_after - 'endpoint' - 'p256dh' - 'auth')
               || pg_catalog.jsonb_build_object('endpoint_host',
                    pg_catalog.substring(to_jsonb(new) ->> 'endpoint', '^https?://([^/:?#]+)'));
    if v_before is not null then
      v_before := (v_before - 'endpoint' - 'p256dh' - 'auth')
                  || pg_catalog.jsonb_build_object('endpoint_host',
                       pg_catalog.substring(to_jsonb(old) ->> 'endpoint', '^https?://([^/:?#]+)'));
      if v_before ->> 'org_id' is distinct from v_after ->> 'org_id' then
        v_before := v_before - 'org_id' - 'plant_id' - 'user_id' - 'user_agent';
      end if;
    end if;
  end if;

  -- Security review 2026-11-06 H1 (owner: no names anywhere): who entered / created / updated /
  -- voided a row never reaches the audit images (audit_log.actor_user_id stays: the audit's own actor).
  v_after := v_after - 'entered_by' - 'staff_id' - 'created_by' - 'voided_by' - 'updated_by' - 'updated_by_staff_id' - 'done_by';
  if v_before is not null then
    v_before := v_before - 'entered_by' - 'staff_id' - 'created_by' - 'voided_by' - 'updated_by' - 'updated_by_staff_id' - 'done_by';
  end if;

  if tg_table_name = 'organizations' then
    v_org := new.id;
  else
    v_org := (v_after ->> 'org_id')::uuid;
  end if;
  if tg_table_name = 'plants' then
    v_plant := new.id;
  else
    v_plant := (v_after ->> 'plant_id')::uuid;
  end if;

  -- devices exists from migration create_devices_and_pairing on (plpgsql resolves at call time).
  select d.id into v_device from public.devices d
   where d.user_id = (select auth.uid()) and d.revoked_at is null;

  insert into public.audit_log (org_id, plant_id, actor_user_id, actor_device_id, action, entity, entity_id, before, after)
  values (v_org, v_plant, (select auth.uid()), v_device, v_action, tg_table_name,
          (v_after ->> 'id')::uuid, v_before, v_after);
  return null;
end;
$function$;
comment on function app.audit() is
  '§4.5/H2 AFTER INSERT/UPDATE: writes audit_log with before/after (pin_hash and lockout counters stripped, lockout-only updates skipped; D12, security L1). push_subscriptions: endpoint, p256dh and auth are never written (only endpoint_host), and a cross-org rebind drops the previous org''s ids from before (security review H1, 2026-11-04). Who-entered keys (entered_by, staff_id, created_by, voided_by, updated_by, updated_by_staff_id, done_by) are stripped from before/after (security review 2026-11-06 H1).';

CREATE OR REPLACE FUNCTION public.mark_route_loaded(p_route_id uuid, p_load_date date, p_client_id uuid, p_loaded boolean DEFAULT true)
 RETURNS public.route_load_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_r     record;
  v_e     public.route_load_events;
  v_today date;
begin
  -- Role check FIRST: a missing route and another tenant's route give the same answer.
  select r.id, r.org_id, r.plant_id, r.days_of_week, r.active, p.timezone into v_r
    from public.routes r join public.plants p on p.id = r.plant_id where r.id = p_route_id;
  if v_r.id is null or not app.has_role(v_r.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'mark_route_loaded requires the manager on duty or an owner';
  end if;
  if not app.has_role(v_r.plant_id, '{owner}')
     and not exists (select 1 from app.managers_on_duty(v_r.plant_id, pg_catalog.now()) u where u = (select auth.uid())) then
    raise exception 'NOT_AUTHORIZED' using detail = 'mark_route_loaded requires the manager on duty or an owner';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  select e.* into v_e from public.route_load_events e where e.client_id = p_client_id;
  if v_e.id is not null then
    if v_e.plant_id = v_r.plant_id then
      return (v_e.id, v_e.route_id, v_e.load_date, v_e.loaded, v_e.occurred_at, false)::public.route_load_result;
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  v_today := (pg_catalog.now() at time zone v_r.timezone)::date;
  if p_load_date is null or p_load_date < v_today - 1 or p_load_date > v_today + 1 then
    raise exception 'VALIDATION_FAILED' using detail = 'load_date: yesterday, today or tomorrow';
  end if;
  if not v_r.active then
    raise exception 'VALIDATION_FAILED' using detail = 'route_id: the route is inactive';
  end if;
  if not (extract(dow from p_load_date)::smallint = any (v_r.days_of_week)) then
    raise exception 'VALIDATION_FAILED' using detail = 'route_id: this route does not run on that weekday';
  end if;
  if p_loaded is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_loaded: true or false';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('route:' || v_r.id::text || p_load_date::text, 0));
  select e.* into v_e from public.route_load_events e
   where e.route_id = v_r.id and e.plant_id = v_r.plant_id and e.load_date = p_load_date
   order by e.occurred_at desc, e.seq desc limit 1;
  if coalesce(v_e.loaded, false) = p_loaded then
    return (v_e.id, v_r.id, p_load_date, p_loaded, v_e.occurred_at, false)::public.route_load_result;
  end if;
  insert into public.route_load_events as e (org_id, plant_id, route_id, load_date, loaded, entered_by, client_id)
  values (v_r.org_id, v_r.plant_id, v_r.id, p_load_date, p_loaded, (select auth.uid()), p_client_id)
  on conflict (client_id) do nothing
  returning e.* into v_e;
  if v_e.id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  -- At most one route_loaded alert per route and load date per 10 minutes (a loaded → not loaded →
  -- loaded flip notifies once; batch review note 5).
  if p_loaded and not exists (
       select 1 from public.alert_events a
         join public.route_load_events x on x.id = a.subject_id and x.plant_id = a.plant_id
        where a.kind = 'route_loaded' and a.plant_id = v_r.plant_id and x.route_id = v_r.id
          and x.load_date = p_load_date and a.sent_at > pg_catalog.now() - interval '10 minutes') then
    insert into public.alert_events (org_id, plant_id, kind, subject_id, recipients)
    values (v_r.org_id, v_r.plant_id, 'route_loaded', v_e.id, '{}');
  end if;
  return (v_e.id, v_e.route_id, v_e.load_date, v_e.loaded, v_e.occurred_at, true)::public.route_load_result;
end;
$function$;
comment on function public.mark_route_loaded(uuid, date, uuid, boolean) is
  'Owner 2026-11-06 RPC (the manager on duty, per app.managers_on_duty, or an owner; definer, role check first): marks a route loaded (p_loaded true) or not loaded (false, to correct a mistake) for p_load_date (yesterday, today or tomorrow, plant-local; the route must run that weekday). Append-only route_load_events; a loaded event alerts the owners (alert_events route_loaded; at most one per route and date per 10 minutes). The route must be active. Same state as now → nothing recorded (changed=false). Idempotent on p_client_id. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
