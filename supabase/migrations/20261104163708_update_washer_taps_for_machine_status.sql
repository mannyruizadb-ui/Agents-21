-- Washer taps after "machine down" and offline taps (owner 2026-11-04):
--
-- 1. start_washer_load gains p_tapped_at (optional): the device time of the tap, so a tap queued
--    offline is recorded when it happened. Bounded to [now − 30 min, now + 1 min] (clock skew);
--    outside → OUT_OF_RANGE_TIMESTAMP (PRD §5.1 "timestamp outside the allowed window", the code
--    undo_washer_load already uses). The shift instance and production day are resolved for the tap
--    time (app.shift_instance_at + the production-date trigger read started_at).
-- 2. A washer that was DOWN at the tap time refuses the tap: MACHINE_DOWN (new app code). A tap made
--    before the washer was marked down (offline, arriving late) is still recorded.
-- 3. undo_washer_load: its 30-minute window and its "did this tap change the queue item" checks now
--    use the cycle's created_at (when the server recorded the tap; the queue item's started_at /
--    completed_at are stamped then), because started_at can now be earlier than the recording.
-- 4. Assigning a queue item to a washer that is down → MACHINE_DOWN (app.check_assignable_washer).
-- 5. get_washroom_board gains is_down / down_reason / down_since (appended columns), and a down
--    washer shows no NEXT (nothing should be loaded into it).

-- ── 4. assignment target must not be down ─────────────────────────────────
create or replace function app.check_assignable_washer(p_machine_id uuid, p_plant_id uuid, p_area_id uuid)
returns void language plpgsql stable set search_path = '' as $$
begin
  if p_machine_id is not null and not exists (
       select 1 from public.machines m
        where m.id = p_machine_id and m.plant_id = p_plant_id and m.area_id = p_area_id
          and m.kind = 'washer' and m.active) then
    raise exception 'VALIDATION_FAILED' using detail = 'assigned_machine_id: not an active washer of this area';
  end if;
  if p_machine_id is not null and app.machine_is_down_at(p_machine_id, p_plant_id, pg_catalog.now()) then
    raise exception 'MACHINE_DOWN' using detail = 'assigned_machine_id: this washer is marked down';
  end if;
end;
$$;
comment on function app.check_assignable_washer(uuid, uuid, uuid) is
  'M2: p_machine_id (if set) must be an active washer of p_area_id in p_plant_id (one VALIDATION_FAILED for foreign, missing, inactive or non-washer machines) and not marked down (MACHINE_DOWN, owner 2026-11-04).';

-- ── 1 + 2. start_washer_load with p_tapped_at ─────────────────────────────
drop function public.start_washer_load(uuid, uuid, uuid, uuid);

create function public.start_washer_load(
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
  'F1/D1 RPC (owner/manager/lead; NO staff session, owner decision 2026-11-02): one tap = one load started on an active washer, at p_tapped_at (the device time of an offline tap; default now; must be within [now − 30 min, now + 1 min], else OUT_OF_RANGE_TIMESTAMP). A washer marked down at that time refuses the tap (MACHINE_DOWN). Picks p_queue_item_id, else the top open item assigned to this washer, else the top open unassigned item of the area (limited to p_wash_group_id when given), else an off-queue load of p_wash_group_id. Writes washer_cycles (source manual, load_count 1, started_at = tap time, group, group''s formula, is_rewash from the queue item, the area''s shift at the tap time, production_date; load_factor_used by trigger) and advances the queue item (loads_started+1; queued→in_progress; done at loads_needed). Idempotent on p_client_id, checked before the time window (duplicate=true, nothing advances twice). Errors: NOT_AUTHORIZED, VALIDATION_FAILED, OUT_OF_RANGE_TIMESTAMP, MACHINE_DOWN, RATE_LIMITED.';
revoke all on function public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz) from public, anon;
grant execute on function public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz) to authenticated, service_role;

-- ── 3. undo_washer_load keyed on created_at ───────────────────────────────
create or replace function public.undo_washer_load(p_cycle_id uuid, p_reason text default null)
returns public.washer_load_result language plpgsql volatile security definer set search_path = '' as $$
declare
  v_w      public.washer_cycles;
  v_q      public.queue_items;
  v_reason text;
  v_need   int;
  v_status app.queue_status;
begin
  select w.* into v_w from public.washer_cycles w where w.id = p_cycle_id;
  if v_w.id is null or not app.has_role(v_w.plant_id, '{owner,manager,lead}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'undo_washer_load requires owner, manager or lead on the cycle''s plant';
  end if;
  if v_w.voided_at is not null then
    return app.washer_load_result(v_w.id, true);   -- idempotent retry
  end if;
  if v_w.source <> 'manual' then
    raise exception 'VALIDATION_FAILED' using detail = 'cycle: only manual washer taps can be undone';
  end if;
  if v_w.created_at < pg_catalog.now() - interval '30 minutes' then
    raise exception 'OUT_OF_RANGE_TIMESTAMP' using detail = 'undo is allowed within 30 minutes of the tap being recorded';
  end if;
  v_reason := coalesce(app.clean_note(p_reason, 200, 'reason'), 'undo');

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('queue:' || v_w.area_id::text, 0));
  update public.washer_cycles w
     set voided_at = pg_catalog.now(), voided_by = (select auth.uid()), void_reason = v_reason
   where w.id = v_w.id and w.voided_at is null;
  if not found then
    return app.washer_load_result(v_w.id, true);   -- a concurrent undo won
  end if;

  if v_w.queue_item_id is not null then
    select q.* into v_q from public.queue_items q
     where q.id = v_w.queue_item_id and q.plant_id = v_w.plant_id for update;
    v_need := app.queue_loads_needed(v_q.wash_group_id, v_q.item_type_id, v_q.qty, v_q.unit);
    v_status := v_q.status;
    -- Reopen only what THIS tap changed: its transaction stamped the item's started_at / completed_at
    -- = the cycle's created_at (the cycle's started_at can be an earlier offline tap time). A cancelled
    -- item, or one completed by hand later, keeps its status.
    if v_q.status = 'done' and v_q.completed_at = v_w.created_at then
      v_status := 'in_progress';
    end if;
    if v_status = 'in_progress' and v_q.loads_started <= 1 and v_q.started_at = v_w.created_at then
      v_status := 'queued';
    end if;
    -- One UPDATE: lowering loads_started is what lets app.bump_queue_version reopen the item.
    update public.queue_items q
       set loads_started = greatest(q.loads_started - 1, 0),
           status = case when q.loads_started > 0 then v_status else q.status end
     where q.id = v_q.id;
  end if;
  return app.washer_load_result(v_w.id, false);
end;
$$;
comment on function public.undo_washer_load(uuid, text) is
  'F1 RPC (owner/manager/lead): undoes a manual washer tap within 30 minutes of when it was recorded (created_at; an offline tap''s started_at can be earlier). VOIDS the cycle (voided_at/by, void_reason = p_reason or ''undo''; excluded from every report; never deleted) and gives the load back to its queue item (loads_started−1; reopens done → in_progress, or in_progress → queued, only if this tap made that change). Already voided → returns it (duplicate=true). Errors: NOT_AUTHORIZED, OUT_OF_RANGE_TIMESTAMP, VALIDATION_FAILED.';

-- ── 5. get_washroom_board + down status ───────────────────────────────────
drop function public.get_washroom_board(uuid);

create function public.get_washroom_board(p_area_id uuid)
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
  v_area record;
  v_now  timestamptz := pg_catalog.now();
begin
  select a.id, a.plant_id into v_area from public.areas a where a.id = p_area_id;
  if v_area.id is null
     or not (app.has_role(v_area.plant_id, '{owner,manager,lead,viewer}')
             or (app.is_display(v_area.plant_id) and (app.my_device()).area_id = v_area.id)) then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_washroom_board requires a role on the area''s plant, or a display of this area';
  end if;

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
         case when s.status = 'down' then s.reason end,
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
  'D1/G6 read (owner/manager/lead/viewer, or a display of this area): one row per ACTIVE washer of the area, in name order: the current (latest live) cycle with group, formula, started_at, expected_end_at = started_at + cycle_minutes, status idle|running|ready|unknown (no cycle time), minutes_ready; and NEXT = the top open item assigned to this washer, else the top open unassigned item (the same unassigned item can be NEXT on several washers: "next free washer"). is_down / down_reason / down_since (owner 2026-11-04): a down washer takes precedence over status, shows no NEXT, and refuses start-taps. server_time for data age. No per-person data.';
revoke all on function public.get_washroom_board(uuid) from public, anon;
grant execute on function public.get_washroom_board(uuid) to authenticated, service_role;
