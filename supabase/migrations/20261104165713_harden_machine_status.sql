-- Security review 2026-11-04 (PASS WITH NOTES) of the machine-down migrations; fixes L1, L3/L4, L5, L6.
--
-- L3/L4  machine_status_events: clients lose every table privilege (incl. PG17 MAINTAIN) and get
--        column-level SELECT without entered_by (who marked a machine down is not shown to anyone).
-- L6     The free-text down reason may name people, so get_washroom_board and get_machine_status
--        return reason only to the owner and managers (null for lead, viewer and display).
--        NOTE: the table's SELECT policy (owner/manager/lead/viewer) still lets a lead or viewer read
--        the reason column directly; narrowing that policy is a role/RLS change left to the owner.
-- L5     Push spam: CHOSEN OPTION = alert cooldown, not a refusal. Every status change is still
--        recorded (the history must stay true, and a washer that really breaks again must be
--        markable), but a down event writes a machine_down alert only when no machine_down alert
--        for the same machine was written in the last 10 minutes. So a down → up → down flip
--        notifies once.
-- L1     A backdated tap could slip past a fresh down event (the washer was "up" at the tap time).
--        Now, on a washer that is down NOW, a tap is accepted only if p_tapped_at is at least 60 s
--        before the down event's occurred_at; otherwise MACHINE_DOWN. A washer that was down AT the
--        tap time still refuses it, as before.

-- ── L3/L4: column-level SELECT without entered_by ─────────────────────────
revoke all on public.machine_status_events from authenticated;
grant select (id, seq, org_id, plant_id, machine_id, status, reason, occurred_at, client_id, created_at)
  on public.machine_status_events to authenticated;

-- ── L1 helper: when did the down status in force at p_ts begin? ───────────
create function app.machine_down_since(p_machine_id uuid, p_plant_id uuid, p_ts timestamptz)
returns timestamptz language sql stable set search_path = '' as $$
  select case when e.status = 'down' then e.occurred_at end
    from public.machine_status_events e
   where e.machine_id = p_machine_id and e.plant_id = p_plant_id and e.occurred_at <= p_ts
   order by e.occurred_at desc, e.seq desc
   limit 1;
$$;
comment on function app.machine_down_since(uuid, uuid, timestamptz) is
  'Security review L1: occurred_at of the down event in force for the machine (in p_plant_id) at p_ts; null when it was up (or never marked). Internal (definer RPCs only).';
revoke all on function app.machine_down_since(uuid, uuid, timestamptz) from public, anon, authenticated;

-- ── L5: set_machine_status alert cooldown ─────────────────────────────────
create or replace function public.set_machine_status(
  p_machine_id uuid,
  p_status     app.machine_status,
  p_client_id  uuid,
  p_reason     text default null)
returns public.machine_status_result language plpgsql volatile security definer set search_path = '' as $$
declare
  v_m      record;
  v_e      public.machine_status_events;
  v_reason text;
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
      return (v_e.id, v_e.machine_id, v_e.status, v_e.reason, v_e.occurred_at, false)::public.machine_status_result;
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  if p_status is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_status: down or up';
  end if;
  v_reason := app.clean_note(p_reason, 200, 'reason');
  if p_status = 'down' and v_reason is null then
    raise exception 'VALIDATION_FAILED' using detail = 'reason: required when marking a machine down (1–200 characters)';
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
    return (v_e.id, v_m.id, p_status, v_e.reason, v_e.occurred_at, false)::public.machine_status_result;
  end if;

  insert into public.machine_status_events as e (org_id, plant_id, machine_id, status, reason, entered_by, client_id)
  values (v_m.org_id, v_m.plant_id, v_m.id, p_status, v_reason, (select auth.uid()), p_client_id)
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
  return (v_e.id, v_e.machine_id, v_e.status, v_e.reason, v_e.occurred_at, true)::public.machine_status_result;
end;
$$;
comment on function public.set_machine_status(uuid, app.machine_status, uuid, text) is
  'Owner 2026-11-04 RPC (owner/manager; definer, role check first, plant-filtered): marks any machine down (p_reason required, 1–200 chars, no control characters; the machine must be active) or back up (p_reason optional). Appends a machine_status_events row. A down event also writes alert_events kind machine_down (subject = event id, recipients ''{}'') for the push sender, unless the same machine already had a machine_down alert in the last 10 minutes (security review L5: a down → up → down flip notifies once; the events are all recorded). Same status as now → nothing recorded (changed=false). Idempotent on p_client_id (returns the recorded event, changed=false). Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';

-- ── L6: get_machine_status reason for owner/manager only ──────────────────
create or replace function public.get_machine_status(p_plant_id uuid)
returns table (
  machine_id   uuid,
  machine_name text,
  kind         app.machine_kind,
  area_id      uuid,
  area_name    text,
  active       boolean,
  status       app.machine_status,   -- up when the machine never went down
  reason       text,                 -- the latest event's reason (down: why)
  since        timestamptz,          -- when the current status began; null = never went down
  server_time  timestamptz)
language plpgsql stable security definer set search_path = '' as $$
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
         coalesce(e.status, 'up'::app.machine_status), case when v_reason then e.reason end, e.occurred_at, pg_catalog.now()
    from public.machines m
    join public.areas a on a.id = m.area_id and a.plant_id = m.plant_id
    left join lateral (
      select x.status, x.reason, x.occurred_at from public.machine_status_events x
       where x.machine_id = m.id and x.plant_id = m.plant_id
       order by x.occurred_at desc, x.seq desc limit 1) e on true
   where m.plant_id = v_plant
     and (m.active or e.status = 'down')
   order by a.name, m.kind, m.name, m.id;
end;
$$;
comment on function public.get_machine_status(uuid) is
  'Owner 2026-11-04 read (owner/manager/lead/viewer of the plant; definer, role check first): one row per active machine of every kind (plus inactive machines still marked down), with area, status (down|up; up when never marked), since (when the current status began; null = never went down), and server_time for data age. reason (the latest event''s free text) only for owner/manager; null for lead/viewer (security review L6). Never returns who marked it. Errors: NOT_AUTHORIZED.';

-- ── L1: start_washer_load on a washer that is down now ────────────────────
create or replace function public.start_washer_load(
  p_machine_id    uuid,
  p_client_id     uuid,
  p_queue_item_id uuid default null,
  p_wash_group_id uuid default null,
  p_tapped_at     timestamptz default null)
returns public.washer_load_result language plpgsql volatile security definer set search_path = '' as $$
declare
  v_m      record;
  v_q      public.queue_items;
  v_group  uuid;
  v_cycle  uuid;
  v_need   int;
  v_now    timestamptz := pg_catalog.now();
  v_ts     timestamptz;
  v_down   timestamptz;
  v_existing record;
begin
  -- Role check FIRST: a missing machine and another tenant's machine give the same answer.
  select m.id, m.org_id, m.plant_id, m.area_id, m.kind, m.active into v_m from public.machines m where m.id = p_machine_id;
  if v_m.id is null or not app.has_role(v_m.plant_id, '{owner,manager,lead}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'start_washer_load requires owner, manager or lead on the washer''s plant';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  -- Idempotency before the time window: an offline retry of a tap that was already saved returns it.
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

  -- Serialize with the queue RPCs of this area (positions, loads_started).
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('queue:' || v_m.area_id::text, 0));

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
  return app.washer_load_result(v_cycle, false);
end;
$$;
comment on function public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz) is
  'F1/D1 RPC (owner/manager/lead; NO staff session, owner decision 2026-11-02): one tap = one load started on an active washer, at p_tapped_at (the device time of an offline tap; default now; must be within [now − 30 min, now + 1 min], else OUT_OF_RANGE_TIMESTAMP). A washer marked down at that time refuses the tap (MACHINE_DOWN); a washer that is down now accepts only a tap at least 60 s before its down event (security review L1). Picks p_queue_item_id, else the top open item assigned to this washer, else the top open unassigned item of the area (limited to p_wash_group_id when given), else an off-queue load of p_wash_group_id. Writes washer_cycles (source manual, load_count 1, started_at = tap time, group, group''s formula, is_rewash from the queue item, the area''s shift at the tap time, production_date; load_factor_used by trigger) and advances the queue item (loads_started+1; queued→in_progress; done at loads_needed). Idempotent on p_client_id, checked before the time window (duplicate=true, nothing advances twice). Errors: NOT_AUTHORIZED, VALIDATION_FAILED, OUT_OF_RANGE_TIMESTAMP, MACHINE_DOWN, RATE_LIMITED.';

-- ── L6: get_washroom_board reason for owner/manager only ──────────────────
create or replace function public.get_washroom_board(p_area_id uuid)
returns table (
  machine_id                  uuid,
  machine_name                text,
  load_factor                 numeric,
  status                      text,          -- idle | running | ready | unknown (no cycle time); see is_down
  cycle_id                    uuid,
  wash_group_id               uuid,
  wash_group_name             text,
  wash_group_name_i18n        jsonb,
  wash_group_color_hex        text,
  is_rewash                   boolean,
  wash_formula_id             uuid,
  formula_external_no         text,
  formula_name                text,
  cycle_minutes               int,
  started_at                  timestamptz,
  expected_end_at             timestamptz,
  minutes_since_start         int,
  minutes_ready               int,           -- minutes since expected_end_at while ready (idle washer cost)
  queue_item_id               uuid,
  next_queue_item_id          uuid,
  next_is_assigned            boolean,       -- true = the owner pinned it to this washer
  next_wash_group_id          uuid,
  next_wash_group_name        text,
  next_wash_group_name_i18n   jsonb,
  next_wash_group_color_hex   text,
  next_item_type_id           uuid,
  next_item_name              text,
  next_item_name_i18n         jsonb,
  next_qty                    numeric,
  next_unit                   app.qty_unit,
  next_is_rush                boolean,
  next_is_rewash              boolean,
  next_loads_remaining        int,
  next_version                int,
  server_time                 timestamptz,
  is_down                     boolean,       -- owner 2026-11-04: marked down (takes precedence over status)
  down_reason                 text,          -- why (null when up)
  down_since                  timestamptz)   -- when it was marked down (null when up)
language plpgsql stable security definer set search_path = '' as $$
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
         case when s.status = 'down' then s.occurred_at end
    from public.machines m
    left join lateral (
      select e.status, e.reason, e.occurred_at from public.machine_status_events e
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
$$;
comment on function public.get_washroom_board(uuid) is
  'D1/G6 read (owner/manager/lead/viewer, or a display of this area): one row per ACTIVE washer of the area, in name order: the current (latest live) cycle with group, formula, started_at, expected_end_at = started_at + cycle_minutes, status idle|running|ready|unknown (no cycle time), minutes_ready; and NEXT = the top open item assigned to this washer, else the top open unassigned item (the same unassigned item can be NEXT on several washers: "next free washer"). is_down / down_reason / down_since (owner 2026-11-04; down_reason only for owner/manager, null for lead, viewer and display: security review L6): a down washer takes precedence over status, shows no NEXT, and refuses start-taps. server_time for data age. No per-person data.';
