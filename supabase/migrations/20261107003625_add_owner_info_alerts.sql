-- Owner information alerts (owner 2026-11-06, C): the producers of estimate_entered, rewash_added and
-- off_queue_start (customer_delivery is written by record_customer_delivery, 20261107003623), and the
-- payloads of all four kinds. Levels (push | quiet | off) and recipients: 20261107003621. Every new kind
-- is informational (still_current = false, always clearable) and its payload carries no person names
-- and no free text.
--
-- * estimate_entered (record_soil_estimate): one alert per entry batch = the estimates one account
--   records on a plant within 10 minutes of the batch's first one. subject = that first estimate. To
--   group by arrival time (entered_at can be an offline device time up to 6 h back), soil_estimates gets
--   recorded_at (server time of the insert; null for rows written before this migration). Payload:
--   first_estimate_id, count, estimates[{estimate_id, wash_group_id, wash_group_name,
--   wash_group_name_i18n, customer_id, qty, unit, qty_loads, entered_at}].
-- * rewash_added (create_queue_item): when a MANAGER (not an owner) adds a rewash item; never on an
--   idempotent retry. subject = the queue item. Payload: queue_item_id, area_id, area_name, wash group,
--   customer_id, qty, unit, qty_loads, status, created_at (the item's note is free text: left out).
-- * off_queue_start (start_washer_load; signature and contract unchanged): when a NEW load starts that is
--   off the queue (no queue item), or whose group is not the group the queue had next for that washer
--   (its top open assigned item, else the area's top open unassigned item, judged under the area lock
--   before the tap). subject = the cycle; dedupe_key = the expected group (null = nothing queued). No
--   tapper (taps carry no name). Payload: cycle_id, machine_id, machine_name, area_name, wash group,
--   customer_id, is_rewash, started_at, queue_item_id, off_queue, expected_wash_group_id/_name/_name_i18n,
--   voided.
-- * customer_delivery payload: delivery_id, customer_id, customer_name, customer_name_i18n, delivered_at,
--   voided, total_bins, lines[{wash_group_id, wash_group_name, wash_group_name_i18n, bins, loads}].
-- washer_cycles.customer_id is snapshotted by trigger (20261107003619) on every insert path.

alter table public.soil_estimates add column recorded_at timestamptz;
alter table public.soil_estimates alter column recorded_at set default now();
comment on column public.soil_estimates.recorded_at is
  'Owner 2026-11-06 (C): server time the estimate was recorded (entered_at can be an offline device time). Groups estimates into one estimate_entered alert. Null for rows recorded before 2026-11-07.';
grant select (recorded_at) on public.soil_estimates to authenticated;

-- ── record_soil_estimate: + estimate_entered ──────────────────────────────
CREATE OR REPLACE FUNCTION public.record_soil_estimate(p_wash_group_id uuid, p_qty numeric, p_unit app.qty_unit, p_client_id uuid, p_staff_session_id uuid, p_note text DEFAULT NULL::text, p_entered_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS soil_estimates
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_g     record;
  v_row   public.soil_estimates;
  v_note  text;
  v_staff uuid;
  v_now   timestamptz := pg_catalog.now();
  v_ts    timestamptz;
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
  v_staff := app.use_staff_session(p_staff_session_id, v_g.plant_id);

  insert into public.soil_estimates as e (org_id, plant_id, wash_group_id, qty, unit, note, entered_by, staff_id, client_id, entered_at)
  values (v_g.org_id, v_g.plant_id, v_g.id, p_qty, p_unit, v_note, (select auth.uid()), v_staff, p_client_id, v_ts)
  on conflict (client_id) do nothing
  returning e.* into v_row;
  if v_row.id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';   -- concurrent retry; the client refetches
  end if;
  -- Owner 2026-11-06 (C): one estimate_entered alert per entry batch = the estimates one account records
  -- on this plant within 10 minutes of the batch's first one (that alert's sent_at). Serialized per
  -- (plant, account), so two estimates of one batch never open two alerts.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('estimate_alert:' || v_g.plant_id::text || ':' || (select auth.uid())::text, 0));
  if not exists (select 1 from public.alert_events a
                   join public.soil_estimates s on s.id = a.subject_id and s.plant_id = a.plant_id
                  where a.kind = 'estimate_entered' and a.plant_id = v_g.plant_id
                    and s.entered_by = (select auth.uid())
                    and a.sent_at > pg_catalog.now() - interval '10 minutes') then
    perform app.raise_owner_alert(v_g.org_id, v_g.plant_id, 'estimate_entered', v_row.id);
  end if;
  return v_row;
end;
$function$;
comment on function public.record_soil_estimate(uuid, numeric, app.qty_unit, uuid, uuid, text, timestamptz) is
  'B1 RPC (owner/manager + staff session, A8): appends a soil estimate for a wash group (never updates; 0 = cleared). qty 0–10,000 (2 decimals; e.g. 2.75 bins) in load, or basket / bin when the group allows it; note ≤ 280; p_entered_at = the device time of an offline entry (default now; within [now − 6 h, now + 1 min], else OUT_OF_RANGE_TIMESTAMP). Owner 2026-11-06: the first estimate of an entry batch (one account, one plant, 10 minutes) writes an estimate_entered owner alert. Idempotent on p_client_id, checked before the time window and the session (returns the existing row, even after the single-use session is spent; no second alert). Returns the soil_estimates row. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, OUT_OF_RANGE_TIMESTAMP, STAFF_SESSION_REQUIRED.';

-- ── create_queue_item: + rewash_added ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.create_queue_item(p_area_id uuid, p_qty numeric, p_unit app.qty_unit, p_client_id uuid, p_wash_group_id uuid DEFAULT NULL::uuid, p_item_type_id uuid DEFAULT NULL::uuid, p_is_rush boolean DEFAULT false, p_note text DEFAULT NULL::text, p_assigned_machine_id uuid DEFAULT NULL::uuid, p_is_rewash boolean DEFAULT false)
 RETURNS queue_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_area  record;
  v_group uuid;
  v_item_group uuid;
  v_note  text;
  v_row   public.queue_items;
  v_new   boolean := false;
begin
  select a.id, a.org_id, a.plant_id, a.kind, a.active into v_area from public.areas a where a.id = p_area_id;
  if v_area.id is null or not app.has_role(v_area.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'create_queue_item requires owner (or manager, rewash only) on the area''s plant';
  end if;
  -- Manager exception 2: rewash only, not rush, not assigned, in load / basket / bin.
  if not app.has_role(v_area.plant_id, '{owner}')
     and not coalesce(p_is_rewash is true and p_is_rush is false and p_assigned_machine_id is null
                      and p_unit in ('load', 'basket', 'bin'), false) then
    raise exception 'NOT_AUTHORIZED' using detail = 'managers may only add rewash items (not rush, not assigned) in loads, baskets or bins';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  -- Idempotency: a retry returns the row it created (same plant only).
  select q.* into v_row from public.queue_items q where q.client_id = p_client_id;
  if v_row.id is not null then
    if v_row.plant_id = v_area.plant_id then
      return v_row;
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;

  if not v_area.active then
    raise exception 'VALIDATION_FAILED' using detail = 'area_id: area is inactive';
  end if;
  if p_item_type_id is not null then
    select i.wash_group_id into v_item_group from public.item_types i
     where i.id = p_item_type_id and i.plant_id = v_area.plant_id and i.active;
    if v_item_group is null then
      raise exception 'VALIDATION_FAILED' using detail = 'item_type_id: no active item with this id in the plant';
    end if;
  end if;
  v_group := coalesce(p_wash_group_id, v_item_group);
  if v_group is null or not exists (select 1 from public.wash_groups g
                                     where g.id = v_group and g.plant_id = v_area.plant_id and g.active) then
    raise exception 'VALIDATION_FAILED' using detail = 'wash_group_id: no active wash group with this id in the plant';
  end if;
  if v_item_group is not null and v_item_group <> v_group then
    raise exception 'VALIDATION_FAILED' using detail = 'item_type_id: the item is not in this wash group';
  end if;
  perform app.check_queue_qty_unit(v_area.plant_id, p_item_type_id, p_qty, p_unit);
  v_note := app.clean_note(p_note, 140, 'note');
  if p_is_rush is null or p_is_rewash is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_is_rush, p_is_rewash: not null';
  end if;
  if p_is_rewash and v_area.kind <> 'washroom' then
    raise exception 'VALIDATION_FAILED' using detail = 'is_rewash: only washroom work can be a rewash';
  end if;
  perform app.check_assignable_washer(p_assigned_machine_id, v_area.plant_id, v_area.id);

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('queue:' || v_area.id::text, 0));
  -- C1: RUSH lands at the top of the rush items, normal work at the bottom of the normal items.
  insert into public.queue_items as q (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position,
                                       is_rush, note, created_by, client_id, assigned_machine_id, is_rewash)
  values (v_area.org_id, v_area.plant_id, v_area.id, v_group, p_item_type_id, p_qty, p_unit,
          app.queue_edge_position(v_area.id, p_is_rush, p_is_rush, null),
          p_is_rush, v_note, (select auth.uid()), p_client_id, p_assigned_machine_id, p_is_rewash)
  on conflict (client_id) do nothing
  returning q.* into v_row;
  v_new := v_row.id is not null;
  if v_row.id is null then   -- a concurrent retry won the race
    select q.* into v_row from public.queue_items q where q.client_id = p_client_id and q.plant_id = v_area.plant_id;
    if v_row.id is null then
      raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
    end if;
  end if;
  -- Owner 2026-11-06 (C): a manager's rewash tells the owners (rewash_added; never on a retry).
  if v_new and p_is_rewash and not app.has_role(v_area.plant_id, '{owner}') then
    perform app.raise_owner_alert(v_area.org_id, v_area.plant_id, 'rewash_added', v_row.id);
  end if;
  return v_row;
end;
$function$;
comment on function public.create_queue_item(uuid, numeric, app.qty_unit, uuid, uuid, uuid, boolean, text, uuid, boolean) is
  'C1 RPC (owner; manager only for a rewash: p_is_rewash true, not rush, no washer, unit load|basket|bin — anything else NOT_AUTHORIZED, owner 2026-11-04; no staff session): adds work to an area''s queue. p_wash_group_id or p_item_type_id (item must be in the group; the group defaults to the item''s); qty 0.01–100,000 in load|basket|bin|piece|pack (piece/pack need an item, pack a pack item); note ≤ 140; RUSH → top of the rush items, else bottom of the normal items; p_assigned_machine_id = an active washer of the area that is not down (null = next free washer); p_is_rewash only in a washroom area. customer_id = the wash group''s customer (trigger). Owner 2026-11-06: a manager''s new rewash item writes a rewash_added owner alert. Idempotent on p_client_id (returns the existing row; no second alert). Returns the queue_items row. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, COUNT_MODE_MISMATCH, MACHINE_DOWN.';

-- ── start_washer_load: + off_queue_start (signature and contract unchanged) ──
CREATE OR REPLACE FUNCTION public.start_washer_load(p_machine_id uuid, p_client_id uuid, p_queue_item_id uuid DEFAULT NULL::uuid, p_wash_group_id uuid DEFAULT NULL::uuid, p_tapped_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_confirm_running boolean DEFAULT false)
 RETURNS washer_load_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_m        record;
  v_q        public.queue_items;
  v_group    uuid;
  v_cycle    uuid;
  v_need     int;
  v_now      timestamptz := pg_catalog.now();
  v_ts       timestamptz;
  v_down     timestamptz;
  v_existing record;
  v_end      timestamptz;
  v_next     record;
begin
  -- Role check FIRST: a missing machine and another tenant's machine give the same answer.
  select m.id, m.org_id, m.plant_id, m.area_id, m.kind, m.active into v_m from public.machines m where m.id = p_machine_id;
  if v_m.id is null or not app.has_role(v_m.plant_id, '{owner,manager,lead}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'start_washer_load requires owner, manager or lead on the washer''s plant';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  -- Idempotency before the time window and the running guard: an offline retry of a tap that was
  -- already saved returns it.
  select w.id, w.plant_id into v_existing from public.washer_cycles w where w.client_id = p_client_id;
  if v_existing.id is not null then
    if v_existing.plant_id = v_m.plant_id then
      return app.washer_load_result(v_existing.id, true);   -- idempotent retry: nothing advances twice
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  if v_m.kind <> 'washer' or not v_m.active then
    raise exception 'VALIDATION_FAILED' using detail = 'machine_id: not an active washer';
  end if;
  v_ts := coalesce(p_tapped_at, v_now);
  if v_ts < v_now - interval '30 minutes' or v_ts > v_now + interval '1 minute' then
    raise exception 'OUT_OF_RANGE_TIMESTAMP' using detail = 'p_tapped_at: must be within the last 30 minutes (up to 1 minute ahead)';
  end if;
  if app.machine_is_down_at(v_m.id, v_m.plant_id, v_ts) then
    raise exception 'MACHINE_DOWN' using detail = 'machine_id: this washer is marked down; mark it up first';
  end if;
  -- L1: down NOW → only a tap clearly before the down event (≥ 60 s) is accepted.
  v_down := app.machine_down_since(v_m.id, v_m.plant_id, v_now);
  if v_down is not null and v_ts > v_down - interval '60 seconds' then
    raise exception 'MACHINE_DOWN' using detail = 'machine_id: this washer is marked down; the tap is not clearly before that';
  end if;
  if p_wash_group_id is not null and not exists (
       select 1 from public.wash_groups g where g.id = p_wash_group_id and g.plant_id = v_m.plant_id and g.active) then
    raise exception 'VALIDATION_FAILED' using detail = 'wash_group_id: no active wash group with this id in the plant';
  end if;

  -- Serialize with the queue RPCs and every other start/undo of this area (positions, loads_started,
  -- the running guard below).
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('queue:' || v_m.area_id::text, 0));

  -- Re-check idempotency under the lock: a concurrent retry of the same tap that committed while we
  -- waited is a duplicate, not a second load on a running washer.
  select w.id, w.plant_id into v_existing from public.washer_cycles w where w.client_id = p_client_id;
  if v_existing.id is not null then
    if v_existing.plant_id = v_m.plant_id then
      return app.washer_load_result(v_existing.id, true);
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;

  -- Owner 2026-11-06 (C): what the queue had next for this washer (its top open item, else the area's
  -- top open unassigned item), before this tap changes anything; for the off_queue_start alert.
  select q.id, q.wash_group_id into v_next from public.queue_items q
   where q.plant_id = v_m.plant_id and q.area_id = v_m.area_id
     and q.status in ('queued', 'in_progress')
     and (q.assigned_machine_id = v_m.id or q.assigned_machine_id is null)
   order by (q.assigned_machine_id is not null) desc, q.is_rush desc, q.position, q.id
   limit 1;

  if p_queue_item_id is not null then
    select q.* into v_q from public.queue_items q
     where q.id = p_queue_item_id and q.plant_id = v_m.plant_id and q.area_id = v_m.area_id
       and q.status in ('queued', 'in_progress')
       for update;
    if v_q.id is null then
      raise exception 'VALIDATION_FAILED' using detail = 'queue_item_id: not an open queue item of this washer''s area';
    end if;
    if p_wash_group_id is not null and p_wash_group_id <> v_q.wash_group_id then
      raise exception 'VALIDATION_FAILED' using detail = 'wash_group_id: does not match the queue item';
    end if;
  else
    select q.* into v_q from public.queue_items q
     where q.plant_id = v_m.plant_id and q.area_id = v_m.area_id
       and q.status in ('queued', 'in_progress')
       and (q.assigned_machine_id = v_m.id or q.assigned_machine_id is null)
       and (p_wash_group_id is null or q.wash_group_id = p_wash_group_id)
     order by (q.assigned_machine_id is not null) desc, q.is_rush desc, q.position, q.id
     limit 1
       for update;
  end if;

  v_group := coalesce(v_q.wash_group_id, p_wash_group_id);
  if v_group is null then
    raise exception 'VALIDATION_FAILED' using detail = 'nothing queued for this washer: choose a wash group';
  end if;

  -- Owner 2026-11-06: a washer still running at the tap time needs an explicit confirmation.
  -- Checked after every validation error, so a confirmed retry cannot fail on something else first.
  -- Any live cycle of this washer whose expected end (started_at + its formula's cycle_minutes) is
  -- after the tap time counts, including one started after an offline tap's time (they overlap).
  -- cycle_minutes ≤ 300 (wash_formulas CHECK) bounds the scan. Unknown cycle time → no guard.
  if not coalesce(p_confirm_running, false) then
    select max(w.started_at + pg_catalog.make_interval(mins => f.cycle_minutes)) into v_end
      from public.washer_cycles w
      join public.wash_formulas f on f.id = w.wash_formula_id
     where w.machine_id = v_m.id and w.plant_id = v_m.plant_id
       and w.voided_at is null
       and f.cycle_minutes is not null
       and w.started_at > v_ts - interval '300 minutes'
       and w.started_at + pg_catalog.make_interval(mins => f.cycle_minutes) > v_ts;
    if v_end is not null then
      raise exception 'WASHER_RUNNING' using detail = 'machine_id: still running until '
        || pg_catalog.to_char(v_end at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        || '; confirm to start another';
    end if;
  end if;

  insert into public.washer_cycles as w (org_id, plant_id, area_id, machine_id, wash_group_id, wash_formula_id,
                                         shift_instance_id, started_at, load_count, source, entered_by, client_id,
                                         is_rewash, queue_item_id)
  select v_m.org_id, v_m.plant_id, v_m.area_id, v_m.id, v_group, g.wash_formula_id,
         app.shift_instance_at(v_m.area_id, v_ts), v_ts, 1, 'manual', (select auth.uid()), p_client_id,
         coalesce(v_q.is_rewash, false), v_q.id
    from public.wash_groups g
   where g.id = v_group and g.plant_id = v_m.plant_id
  on conflict (client_id) do nothing
  returning w.id into v_cycle;
  if v_cycle is null then   -- a concurrent retry won the race
    select w.id into v_cycle from public.washer_cycles w where w.client_id = p_client_id and w.plant_id = v_m.plant_id;
    if v_cycle is null then
      raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
    end if;
    return app.washer_load_result(v_cycle, true);
  end if;

  if v_q.id is not null then
    update public.queue_items q
       set loads_started = q.loads_started + 1,
           status = case when q.status = 'queued' then 'in_progress'::app.queue_status else q.status end
     where q.id = v_q.id
    returning q.* into v_q;
    v_need := app.queue_loads_needed(v_q.wash_group_id, v_q.item_type_id, v_q.qty, v_q.unit);
    if v_need is not null and v_q.loads_started >= v_need then
      update public.queue_items q set status = 'done' where q.id = v_q.id;
    end if;
  end if;
  -- Owner 2026-11-06 (C): off_queue_start when the load is off the queue, or its group is not the group
  -- the queue had next for this washer (dedupe_key = that group; null = nothing was queued). No tapper.
  if v_q.id is null or v_next.id is null or v_q.wash_group_id is distinct from v_next.wash_group_id then
    perform app.raise_owner_alert(v_m.org_id, v_m.plant_id, 'off_queue_start', v_cycle, v_next.wash_group_id::text);
  end if;
  return app.washer_load_result(v_cycle, false);
end;
$function$;
comment on function public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean) is
  'F1/D1 RPC (owner/manager/lead; NO staff session, owner decision 2026-11-02): one tap = one load started on an active washer, at p_tapped_at (the device time of an offline tap; default now; must be within [now − 30 min, now + 1 min], else OUT_OF_RANGE_TIMESTAMP). A washer marked down at that time refuses the tap (MACHINE_DOWN); a washer that is down now accepts only a tap at least 60 s before its down event (security review L1). Owner 2026-11-06: a washer still RUNNING at the tap time (a live, non-voided cycle of it with started_at + its formula''s cycle_minutes after the tap time — the get_washroom_board rule; a cycle with unknown cycle time never blocks) refuses the tap with WASHER_RUNNING (detail names the expected end in UTC) unless p_confirm_running = true; checked under the area lock, so it is race-safe. Picks p_queue_item_id, else the top open item assigned to this washer, else the top open unassigned item of the area (limited to p_wash_group_id when given), else an off-queue load of p_wash_group_id. Writes washer_cycles (source manual, load_count 1, started_at = tap time, group, group''s formula, is_rewash from the queue item, the area''s shift at the tap time, production_date; load_factor_used and customer_id (the group''s customer, 2026-11-06) by trigger) and advances the queue item (loads_started+1; queued→in_progress; done at loads_needed). Owner 2026-11-06: a new load that is off the queue, or whose group is not what the queue had next for this washer, writes an off_queue_start owner alert (no tapper). Idempotent on p_client_id, checked before the time window and the running guard, and again under the lock (duplicate=true, nothing advances twice, no alert). Errors: NOT_AUTHORIZED, VALIDATION_FAILED, OUT_OF_RANGE_TIMESTAMP, MACHINE_DOWN, WASHER_RUNNING, RATE_LIMITED.';

-- ── alert_payload: + the four owner information kinds ─────────────────────
CREATE OR REPLACE FUNCTION app.alert_payload(p_alert alert_events)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v jsonb;
begin
  if p_alert.kind = 'machine_down' then
    select pg_catalog.jsonb_build_object(
             'machine_id', m.id, 'machine_name', m.name, 'machine_kind', m.kind, 'area_name', ar.name,
             'reason_code', e.reason_code, 'reason_label_i18n', r.label_i18n, 'down_since', e.occurred_at,
             'still_down', app.machine_is_down_at(m.id, m.plant_id, pg_catalog.now()))
      into v
      from public.machine_status_events e
      join public.machines m on m.id = e.machine_id and m.plant_id = e.plant_id
      join public.areas ar on ar.id = m.area_id and ar.plant_id = m.plant_id
      left join public.machine_down_reasons r on r.plant_id = e.plant_id and r.code = e.reason_code
     where e.id = p_alert.subject_id and e.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'washer_idle' then
    select pg_catalog.jsonb_build_object(
             'machine_id', m.id, 'machine_name', m.name, 'area_name', ar.name,
             'idle_since', greatest(c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes),
                                    (select max(si.starts_at) from public.shift_instances si
                                      where si.area_id = m.area_id and si.plant_id = m.plant_id and si.skipped_at is null
                                        and si.starts_at <= p_alert.sent_at and si.ends_at > p_alert.sent_at)),
             'still_idle', not exists (select 1 from public.washer_cycles w2
                                        where w2.machine_id = m.id and w2.plant_id = m.plant_id and w2.voided_at is null
                                          and (w2.started_at, w2.id) > (c.started_at, c.id)))
      into v
      from public.machines m
      join public.areas ar on ar.id = m.area_id and ar.plant_id = m.plant_id
      left join public.washer_cycles c on c.id::text = p_alert.dedupe_key and c.plant_id = m.plant_id
      left join public.wash_formulas f on f.id = c.wash_formula_id
     where m.id = p_alert.subject_id and m.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'route_loaded' then
    select pg_catalog.jsonb_build_object(
             'route_id', r.id, 'route_name', r.name, 'load_time', r.load_time, 'load_date', e.load_date,
             'loaded_at', e.occurred_at)
      into v
      from public.route_load_events e
      join public.routes r on r.id = e.route_id and r.plant_id = e.plant_id
     where e.id = p_alert.subject_id and e.plant_id = p_alert.plant_id;
  elsif p_alert.kind in ('task_assigned', 'task_done') then
    -- The task's own text goes to its assignees (task_assigned) and back to the owners (task_done).
    -- The done note and any names never go in a payload.
    select pg_catalog.jsonb_build_object(
             'task_id', t.id, 'body', t.body, 'to_on_duty', t.to_on_duty, 'created_at', t.created_at,
             'reminder', case when p_alert.kind = 'task_assigned' then coalesce(p_alert.dedupe_key, '0')::int end,
             'done_at', t.done_at, 'reviewed_at', t.reviewed_at)
      into v
      from public.tasks t
     where t.id = p_alert.subject_id and t.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'customer_delivery' then
    -- Owner 2026-11-06: customer, when, and per line the group + bins (+ loads); no names, no note.
    select pg_catalog.jsonb_build_object(
             'delivery_id', d.id, 'customer_id', c.id, 'customer_name', c.name, 'customer_name_i18n', c.name_i18n,
             'delivered_at', d.delivered_at, 'voided', d.voided_at is not null,
             'total_bins', (select sum(l.bins) from public.customer_delivery_lines l
                             where l.delivery_id = d.id and l.plant_id = d.plant_id),
             'lines', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                                  'wash_group_id', g.id, 'wash_group_name', g.name, 'wash_group_name_i18n', g.name_i18n,
                                  'bins', l.bins, 'loads', l.loads) order by l.line_no)
                                  from public.customer_delivery_lines l
                                  join public.wash_groups g on g.id = l.wash_group_id and g.plant_id = l.plant_id
                                 where l.delivery_id = d.id and l.plant_id = d.plant_id), '[]'::jsonb))
      into v
      from public.customer_deliveries d
      join public.customers c on c.id = d.customer_id and c.plant_id = d.plant_id
     where d.id = p_alert.subject_id and d.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'estimate_entered' then
    -- The batch: estimates the same account recorded on the plant within 10 minutes of the first one
    -- (the alert's subject). The account is only used to group; it is never in the payload.
    select pg_catalog.jsonb_build_object(
             'first_estimate_id', f.id,
             'count', (select count(*) from public.soil_estimates e
                        where e.plant_id = f.plant_id and e.entered_by = f.entered_by
                          and e.recorded_at >= p_alert.sent_at and e.recorded_at < p_alert.sent_at + interval '10 minutes'),
             'estimates', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                                      'estimate_id', e.id, 'wash_group_id', g.id, 'wash_group_name', g.name,
                                      'wash_group_name_i18n', g.name_i18n, 'customer_id', g.customer_id,
                                      'qty', e.qty, 'unit', e.unit,
                                      'qty_loads', app.to_loads(e.wash_group_id, null, e.qty, e.unit),
                                      'entered_at', e.entered_at) order by e.recorded_at, e.id)
                                      from public.soil_estimates e
                                      join public.wash_groups g on g.id = e.wash_group_id and g.plant_id = e.plant_id
                                     where e.plant_id = f.plant_id and e.entered_by = f.entered_by
                                       and e.recorded_at >= p_alert.sent_at
                                       and e.recorded_at < p_alert.sent_at + interval '10 minutes'), '[]'::jsonb))
      into v
      from public.soil_estimates f
     where f.id = p_alert.subject_id and f.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'rewash_added' then
    select pg_catalog.jsonb_build_object(
             'queue_item_id', q.id, 'area_id', ar.id, 'area_name', ar.name,
             'wash_group_id', g.id, 'wash_group_name', g.name, 'wash_group_name_i18n', g.name_i18n,
             'customer_id', q.customer_id, 'qty', q.qty, 'unit', q.unit,
             'qty_loads', app.to_loads(q.wash_group_id, q.item_type_id, q.qty, q.unit),
             'status', q.status, 'created_at', q.created_at)
      into v
      from public.queue_items q
      join public.areas ar on ar.id = q.area_id and ar.plant_id = q.plant_id
      join public.wash_groups g on g.id = q.wash_group_id and g.plant_id = q.plant_id
     where q.id = p_alert.subject_id and q.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'off_queue_start' then
    select pg_catalog.jsonb_build_object(
             'cycle_id', w.id, 'machine_id', m.id, 'machine_name', m.name, 'area_name', ar.name,
             'wash_group_id', g.id, 'wash_group_name', g.name, 'wash_group_name_i18n', g.name_i18n,
             'customer_id', w.customer_id, 'is_rewash', w.is_rewash, 'started_at', w.started_at,
             'queue_item_id', w.queue_item_id, 'off_queue', w.queue_item_id is null,
             'expected_wash_group_id', xg.id, 'expected_wash_group_name', xg.name,
             'expected_wash_group_name_i18n', xg.name_i18n,
             'voided', w.voided_at is not null)
      into v
      from public.washer_cycles w
      join public.machines m on m.id = w.machine_id and m.plant_id = w.plant_id
      join public.areas ar on ar.id = w.area_id and ar.plant_id = w.plant_id
      left join public.wash_groups g on g.id = w.wash_group_id and g.plant_id = w.plant_id
      left join public.wash_groups xg on xg.id::text = p_alert.dedupe_key and xg.plant_id = w.plant_id
     where w.id = p_alert.subject_id and w.plant_id = p_alert.plant_id;
  end if;
  return coalesce(v, '{}'::jsonb);
end;
$function$;
comment on function app.alert_payload(public.alert_events) is
  'Owner 2026-11-06: what an alert may show, per kind (jsonb; no free text except a task''s own text to its assignees/owners; never names or notes). machine_down: machine, area, reason_code + label, down_since, still_down. washer_idle: machine, area, idle_since, still_idle. route_loaded: route, load_time, load_date, loaded_at. task_assigned / task_done: task_id, body, to_on_duty, created_at, reminder, done_at, reviewed_at. customer_delivery: delivery_id, customer, delivered_at, voided, total_bins, lines[group, bins, loads]. estimate_entered: first_estimate_id, count, estimates[group, customer_id, qty, unit, qty_loads, entered_at]. rewash_added: queue item, area, group, customer_id, qty, unit, qty_loads, status, created_at. off_queue_start: cycle, machine, area, group, customer_id, is_rewash, started_at, queue_item_id, off_queue, expected group, voided. Internal.';
