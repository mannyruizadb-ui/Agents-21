-- Machine-down reasons as codes (owner 2026-11-04): each viewer sees the preset reason in their own
-- language (the client translates the code), and the free text becomes optional details.
--   * app.machine_down_reason: water_pump, soap_dispenser, wont_start, leaking, other.
--   * machine_status_events.reason_code: required for down (NOT VALID: rows written before this
--     migration keep their free text only), null for up; 'other' requires details (reason).
--   * set_machine_status gains p_reason_code (last, optional). Backward compatible: a down sent with
--     only p_reason is recorded as reason_code 'other' with that text as details. The result type
--     gains reason_code as its LAST attribute.
--   * get_machine_status gains reason_code and get_washroom_board gains down_reason_code (appended
--     columns), with the same per-role hiding as the free text: owner/manager only (security L6).
--   * Clients read reason_code through the column grant (entered_by stays hidden, L3/L4).

create type app.machine_down_reason as enum ('water_pump', 'soap_dispenser', 'wont_start', 'leaking', 'other');
comment on type app.machine_down_reason is
  'Owner 2026-11-04: preset machine-down reasons, translated by the client (water pump, soap dispenser, won''t start, leaking, other = see details).';

alter table public.machine_status_events add column reason_code app.machine_down_reason;
comment on column public.machine_status_events.reason_code is
  'Owner 2026-11-04: preset down reason (required for down; null for up). reason = optional details, required for other.';
comment on column public.machine_status_events.reason is
  'Optional details (1–200 characters, no control characters); required when reason_code = other. Before 2026-11-04 the only reason.';
alter table public.machine_status_events
  drop constraint machine_status_events_down_needs_reason,
  add constraint machine_status_events_down_needs_code check (status <> 'down' or reason_code is not null) not valid,
  add constraint machine_status_events_code_only_for_down check (status = 'down' or reason_code is null),
  add constraint machine_status_events_other_needs_details check (reason_code is distinct from 'other' or reason is not null);
grant select (reason_code) on public.machine_status_events to authenticated;

alter type public.machine_status_result add attribute reason_code app.machine_down_reason;
comment on type public.machine_status_result is
  'set_machine_status result: the event now in force for the machine (event_id, machine_id, status, reason = details, since, changed, reason_code).';

-- ── set_machine_status: + p_reason_code ───────────────────────────────────
drop function public.set_machine_status(uuid, app.machine_status, uuid, text);
CREATE FUNCTION public.set_machine_status(p_machine_id uuid, p_status app.machine_status, p_client_id uuid, p_reason text DEFAULT NULL::text, p_reason_code app.machine_down_reason DEFAULT NULL::app.machine_down_reason)
 RETURNS public.machine_status_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_m      record;
  v_e      public.machine_status_events;
  v_reason text;
  v_code   app.machine_down_reason;
begin
  -- Role check FIRST: a missing machine and another tenant's machine give the same answer.
  select m.id, m.org_id, m.plant_id, m.active into v_m from public.machines m where m.id = p_machine_id;
  if v_m.id is null or not app.has_role(v_m.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'set_machine_status requires owner or manager on the machine''s plant';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  -- Idempotency: a retry returns the event it recorded (same plant only).
  select e.* into v_e from public.machine_status_events e where e.client_id = p_client_id;
  if v_e.id is not null then
    if v_e.plant_id = v_m.plant_id then
      return (v_e.id, v_e.machine_id, v_e.status, v_e.reason, v_e.occurred_at, false, v_e.reason_code)::public.machine_status_result;
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  if p_status is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_status: down or up';
  end if;
  v_reason := app.clean_note(p_reason, 200, 'reason');
  -- Reason code (owner 2026-11-04): down needs a code; the free text is optional details, required
  -- for 'other'. Backward compatible: a down with only p_reason is recorded as 'other' + details.
  v_code := case when p_status = 'down' and p_reason_code is null and v_reason is not null then 'other'
                 else p_reason_code end;
  if p_status = 'down' and v_code is null then
    raise exception 'VALIDATION_FAILED' using detail = 'reason_code: required when marking a machine down (water_pump, soap_dispenser, wont_start, leaking, other)';
  end if;
  if p_status = 'up' and v_code is not null then
    raise exception 'VALIDATION_FAILED' using detail = 'reason_code: only for down';
  end if;
  if v_code = 'other' and v_reason is null then
    raise exception 'VALIDATION_FAILED' using detail = 'reason: details required for reason_code other (1–200 characters)';
  end if;
  if p_status = 'down' and not v_m.active then
    raise exception 'VALIDATION_FAILED' using detail = 'machine_id: the machine is inactive';
  end if;

  -- One status change at a time per machine.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('machine:' || v_m.id::text, 0));
  select e.* into v_e from public.machine_status_events e
   where e.machine_id = v_m.id and e.plant_id = v_m.plant_id
   order by e.occurred_at desc, e.seq desc limit 1;
  if coalesce(v_e.status, 'up') = p_status then
    -- Already in this status: nothing recorded, no alert. Returns the event in force (null when a
    -- machine that never went down is marked up).
    return (v_e.id, v_m.id, p_status, v_e.reason, v_e.occurred_at, false, v_e.reason_code)::public.machine_status_result;
  end if;

  insert into public.machine_status_events as e (org_id, plant_id, machine_id, status, reason, reason_code, entered_by, client_id)
  values (v_m.org_id, v_m.plant_id, v_m.id, p_status, v_reason, v_code, (select auth.uid()), p_client_id)
  on conflict (client_id) do nothing
  returning e.* into v_e;
  if v_e.id is null then   -- a concurrent retry won the race
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;

  -- Push hook: one undelivered alert per down event, at most one per machine per 10 minutes (L5).
  if p_status = 'down' and not exists (
       select 1 from public.alert_events a
         join public.machine_status_events x on x.id = a.subject_id and x.plant_id = a.plant_id
        where a.kind = 'machine_down' and a.plant_id = v_m.plant_id and x.machine_id = v_m.id
          and a.sent_at > pg_catalog.now() - interval '10 minutes') then
    insert into public.alert_events (org_id, plant_id, kind, subject_id, recipients)
    values (v_m.org_id, v_m.plant_id, 'machine_down', v_e.id, '{}');
  end if;
  return (v_e.id, v_e.machine_id, v_e.status, v_e.reason, v_e.occurred_at, true, v_e.reason_code)::public.machine_status_result;
end;
$function$;
comment on function public.set_machine_status(uuid, app.machine_status, uuid, text, app.machine_down_reason) is
  'Owner 2026-11-04 RPC (owner/manager; definer, role check first, plant-filtered): marks any machine down with p_reason_code (water_pump | soap_dispenser | wont_start | leaking | other) and optional details p_reason (1–200 chars, no control characters; required for other; a down with only p_reason is recorded as other) — the machine must be active — or back up (no code; p_reason optional). Appends a machine_status_events row. A down event also writes alert_events kind machine_down (subject = event id, recipients ''{}'') unless the same machine had one in the last 10 minutes (L5). Same status as now → nothing recorded (changed=false). Idempotent on p_client_id (returns the recorded event, changed=false). Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.set_machine_status(uuid, app.machine_status, uuid, text, app.machine_down_reason) from public, anon;
grant execute on function public.set_machine_status(uuid, app.machine_status, uuid, text, app.machine_down_reason) to authenticated, service_role;

-- ── get_machine_status: + reason_code ─────────────────────────────────────
drop function public.get_machine_status(uuid);
CREATE FUNCTION public.get_machine_status(p_plant_id uuid)
 RETURNS TABLE(machine_id uuid, machine_name text, kind app.machine_kind, area_id uuid, area_name text, active boolean, status app.machine_status, reason text, since timestamp with time zone, server_time timestamp with time zone, reason_code app.machine_down_reason)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_plant  uuid;
  v_reason boolean;
begin
  select p.id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant is null or not app.has_role(v_plant, '{owner,manager,lead,viewer}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_machine_status requires a role on the plant';
  end if;
  v_reason := app.has_role(v_plant, '{owner,manager}');   -- L6: free-text reasons for owner/manager only
  return query
  select m.id, m.name, m.kind, m.area_id, a.name, m.active,
         coalesce(e.status, 'up'::app.machine_status), case when v_reason then e.reason end, e.occurred_at, pg_catalog.now(),
         case when v_reason then e.reason_code end
    from public.machines m
    join public.areas a on a.id = m.area_id and a.plant_id = m.plant_id
    left join lateral (
      select x.status, x.reason, x.reason_code, x.occurred_at from public.machine_status_events x
       where x.machine_id = m.id and x.plant_id = m.plant_id
       order by x.occurred_at desc, x.seq desc limit 1) e on true
   where m.plant_id = v_plant
     and (m.active or e.status = 'down')
   order by a.name, m.kind, m.name, m.id;
end;
$function$;
comment on function public.get_machine_status(uuid) is
  'Owner 2026-11-04 read (owner/manager/lead/viewer of the plant; definer, role check first): one row per active machine of every kind (plus inactive machines still marked down), with area, status (down|up; up when never marked), since (when the current status began; null = never went down), server_time for data age, and the latest event''s reason_code (preset, translated by the client) and reason (details) — both only for owner/manager, null for lead/viewer (security review L6). Never returns who marked it. Errors: NOT_AUTHORIZED.';
revoke all on function public.get_machine_status(uuid) from public, anon;
grant execute on function public.get_machine_status(uuid) to authenticated, service_role;

-- ── get_washroom_board: + down_reason_code ────────────────────────────────
drop function public.get_washroom_board(uuid);
CREATE FUNCTION public.get_washroom_board(p_area_id uuid)
 RETURNS TABLE(machine_id uuid, machine_name text, load_factor numeric, status text, cycle_id uuid, wash_group_id uuid, wash_group_name text, wash_group_name_i18n jsonb, wash_group_color_hex text, is_rewash boolean, wash_formula_id uuid, formula_external_no text, formula_name text, cycle_minutes integer, started_at timestamp with time zone, expected_end_at timestamp with time zone, minutes_since_start integer, minutes_ready integer, queue_item_id uuid, next_queue_item_id uuid, next_is_assigned boolean, next_wash_group_id uuid, next_wash_group_name text, next_wash_group_name_i18n jsonb, next_wash_group_color_hex text, next_item_type_id uuid, next_item_name text, next_item_name_i18n jsonb, next_qty numeric, next_unit app.qty_unit, next_is_rush boolean, next_is_rewash boolean, next_loads_remaining integer, next_version integer, server_time timestamp with time zone, is_down boolean, down_reason text, down_since timestamp with time zone, down_reason_code app.machine_down_reason)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_area   record;
  v_now    timestamptz := pg_catalog.now();
  v_reason boolean;
begin
  select a.id, a.plant_id into v_area from public.areas a where a.id = p_area_id;
  if v_area.id is null
     or not (app.has_role(v_area.plant_id, '{owner,manager,lead,viewer}')
             or (app.is_display(v_area.plant_id) and (app.my_device()).area_id = v_area.id)) then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_washroom_board requires a role on the area''s plant, or a display of this area';
  end if;
  v_reason := app.has_role(v_area.plant_id, '{owner,manager}');   -- L6: free-text reasons for owner/manager only

  return query
  select m.id, m.name, m.load_factor,
         case when c.id is null then 'idle'
              when f.cycle_minutes is null then 'unknown'
              when v_now < c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes) then 'running'
              else 'ready' end,
         c.id, c.wash_group_id, g.name, g.name_i18n, g.color_hex, c.is_rewash,
         c.wash_formula_id, f.external_no, f.name, f.cycle_minutes,
         c.started_at,
         c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes),
         (extract(epoch from (v_now - c.started_at)) / 60)::int,
         case when f.cycle_minutes is not null and v_now >= c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes)
              then (extract(epoch from (v_now - (c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes)))) / 60)::int end,
         c.queue_item_id,
         n.id, n.assigned_machine_id is not null, n.wash_group_id, ng.name, ng.name_i18n, ng.color_hex,
         n.item_type_id, ni.name, ni.name_i18n, n.qty, n.unit, n.is_rush, n.is_rewash,
         greatest(app.queue_loads_needed(n.wash_group_id, n.item_type_id, n.qty, n.unit) - n.loads_started, 0),
         n.version,
         v_now,
         coalesce(s.status = 'down', false),
         case when s.status = 'down' and v_reason then s.reason end,
         case when s.status = 'down' then s.occurred_at end,
         case when s.status = 'down' and v_reason then s.reason_code end
    from public.machines m
    left join lateral (
      select e.status, e.reason, e.reason_code, e.occurred_at from public.machine_status_events e
       where e.machine_id = m.id and e.plant_id = m.plant_id
       order by e.occurred_at desc, e.seq desc
       limit 1) s on true
    left join lateral (
      select w.* from public.washer_cycles w
       where w.machine_id = m.id and w.plant_id = m.plant_id and w.voided_at is null
       order by w.started_at desc, w.id desc
       limit 1) c on true
    left join public.wash_groups g on g.id = c.wash_group_id
    left join public.wash_formulas f on f.id = c.wash_formula_id
    left join lateral (
      select q.* from public.queue_items q
       where q.area_id = m.area_id and q.plant_id = m.plant_id
         and q.status in ('queued', 'in_progress')
         and (q.assigned_machine_id = m.id or q.assigned_machine_id is null)
         and s.status is distinct from 'down'            -- a down washer gets no NEXT
       order by (q.assigned_machine_id is not null) desc, q.is_rush desc, q.position, q.id
       limit 1) n on true
    left join public.wash_groups ng on ng.id = n.wash_group_id
    left join public.item_types ni on ni.id = n.item_type_id
   where m.area_id = v_area.id and m.plant_id = v_area.plant_id and m.kind = 'washer' and m.active
   order by m.name, m.id;
end;
$function$;
comment on function public.get_washroom_board(uuid) is
  'D1/G6 read (owner/manager/lead/viewer, or a display of this area): one row per ACTIVE washer of the area, in name order: the current (latest live) cycle with group, formula, started_at, expected_end_at = started_at + cycle_minutes, status idle|running|ready|unknown (no cycle time), minutes_ready; and NEXT = the top open item assigned to this washer, else the top open unassigned item (the same unassigned item can be NEXT on several washers: "next free washer"). is_down / down_reason / down_since (owner 2026-11-04; down_reason only for owner/manager, null for lead, viewer and display: security review L6): a down washer takes precedence over status, shows no NEXT, and refuses start-taps. server_time for data age. No per-person data. down_reason_code (owner 2026-11-04): the preset reason (water_pump | soap_dispenser | wont_start | leaking | other), translated by the client; same per-role hiding as down_reason.';
revoke all on function public.get_washroom_board(uuid) from public, anon;
grant execute on function public.get_washroom_board(uuid) to authenticated, service_role;
