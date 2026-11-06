-- Owner decisions 2026-11-06 (washer taps):
--  1. A START on a washer that is still running must be confirmed. A stray second START on a running
--     washer took a load off the queue with nothing actually washing. start_washer_load gets
--     p_confirm_running (default false); without it, a tap while a live (non-voided) cycle of the same
--     washer is expected to still run at the tap time raises WASHER_RUNNING. "Running" is the
--     get_washroom_board rule: started_at + the cycle's formula cycle_minutes > the tap time. A cycle
--     with no cycle time (unknown) never blocks. The check runs under the area's queue advisory lock
--     (every start/undo of the area takes it), so two concurrent STARTs cannot both pass it.
--  2. undo_washer_load: within 5 minutes of the tap being recorded (created_at), was 30.
-- PostgREST must see ONE start_washer_load signature: the 5-argument version is dropped.

drop function public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz);

create function public.start_washer_load(
  p_machine_id        uuid,
  p_client_id         uuid,
  p_queue_item_id     uuid default null,
  p_wash_group_id     uuid default null,
  p_tapped_at         timestamptz default null,
  p_confirm_running   boolean default false)
returns public.washer_load_result language plpgsql volatile security definer set search_path = '' as $$
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
  return app.washer_load_result(v_cycle, false);
end;
$$;
comment on function public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean) is
  'F1/D1 RPC (owner/manager/lead; NO staff session, owner decision 2026-11-02): one tap = one load started on an active washer, at p_tapped_at (the device time of an offline tap; default now; must be within [now − 30 min, now + 1 min], else OUT_OF_RANGE_TIMESTAMP). A washer marked down at that time refuses the tap (MACHINE_DOWN); a washer that is down now accepts only a tap at least 60 s before its down event (security review L1). Owner 2026-11-06: a washer still RUNNING at the tap time (a live, non-voided cycle of it with started_at + its formula''s cycle_minutes after the tap time — the get_washroom_board rule; a cycle with unknown cycle time never blocks) refuses the tap with WASHER_RUNNING (detail names the expected end in UTC) unless p_confirm_running = true; checked under the area lock, so it is race-safe. Picks p_queue_item_id, else the top open item assigned to this washer, else the top open unassigned item of the area (limited to p_wash_group_id when given), else an off-queue load of p_wash_group_id. Writes washer_cycles (source manual, load_count 1, started_at = tap time, group, group''s formula, is_rewash from the queue item, the area''s shift at the tap time, production_date; load_factor_used by trigger) and advances the queue item (loads_started+1; queued→in_progress; done at loads_needed). Idempotent on p_client_id, checked before the time window and the running guard, and again under the lock (duplicate=true, nothing advances twice). Errors: NOT_AUTHORIZED, VALIDATION_FAILED, OUT_OF_RANGE_TIMESTAMP, MACHINE_DOWN, WASHER_RUNNING, RATE_LIMITED.';
revoke all on function public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean) from public, anon;
grant execute on function public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean) to authenticated, service_role;

-- ── 2. undo_washer_load: 5-minute window (was 30) ─────────────────────────
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
  if v_w.created_at < pg_catalog.now() - interval '5 minutes' then
    raise exception 'OUT_OF_RANGE_TIMESTAMP' using detail = 'undo is allowed within 5 minutes of the tap being recorded';
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
  'F1 RPC (owner/manager/lead): undoes a manual washer tap within 5 minutes of when it was recorded (created_at; owner 2026-11-06, was 30 minutes; an offline tap''s started_at can be earlier). VOIDS the cycle (voided_at/by, void_reason = p_reason or ''undo''; excluded from every report; never deleted) and gives the load back to its queue item (loads_started−1; reopens done → in_progress, or in_progress → queued, only if this tap made that change). Already voided → returns it (duplicate=true). Errors: NOT_AUTHORIZED, OUT_OF_RANGE_TIMESTAMP, VALIDATION_FAILED.';
