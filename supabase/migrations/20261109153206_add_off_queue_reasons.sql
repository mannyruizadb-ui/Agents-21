-- Off-queue start reasons (owner decision 2026-11-09, option a).
--
-- When a washer start runs something other than what the queue had next for that washer (a hand-picked
-- wash group, or an off-queue load), the person gives a one-tap reason:
--   not_ready     the next item's goods are not ready
--   wrong_washer  the next item does not fit this washer
--   urgent        something else is more urgent
--   other
-- The skipped queue item is untouched (it stays at the top). The owner sees a COUNT of today's off-queue
-- starts by reason on the dashboard (get_off_queue_starts). No push, no alert, no names: washer taps stay
-- anonymous, and nothing here reads or returns who tapped.
--
-- * washer_cycles.off_queue (nullable boolean): judged by start_washer_load under the area lock, exactly as
--   the removed off_queue_start alert did (20261107003625, removed by 20261107021207): the queue's next
--   item for this washer is its top open item assigned to this washer, else the area's top open unassigned
--   item (order: assigned first, rush, position, id), BEFORE this tap changes anything. The start is
--   off-queue when the queue had a next item and the start either takes no queue item or runs another group
--   than that next item's. When NOTHING was queued for the washer the start is NOT off-queue (meta/owner
--   2026-11-09: reasons only when someone deviates from an existing queue): off_queue = false, no reason.
--   null = not judged (rows written before 2026-11-09, and any non-tap insert path such
--   as a future Accu-Flow import). No backfill: history keeps null.
-- * washer_cycles.off_queue_reason: one of the four codes; present exactly when off_queue is true (CHECK).
-- * Both are frozen after insert (trigger); corrections stay void + re-enter.
-- * start_washer_load gains p_off_queue_reason (default null). An off-queue start without a reason raises
--   the new app error OFF_QUEUE_REASON_REQUIRED (detail names the expected wash group), after the role
--   check, the idempotency check and every other validation error, and before the WASHER_RUNNING guard, so
--   the client can ask "why?" first and "still running, start anyway?" second; a retry with both answers
--   passes. A reason sent for an on-queue start is ignored (stored null). Enforced immediately: the app and
--   this migration deploy together (the deployed app sends no reason, so a hand-picked group would be
--   refused until the new screens ship).

-- ── Columns ───────────────────────────────────────────────────────────────
alter table public.washer_cycles
  add column off_queue boolean,
  add column off_queue_reason text,
  add constraint washer_cycles_off_queue_reason_check
    check (off_queue_reason is null or off_queue_reason in ('not_ready', 'wrong_washer', 'urgent', 'other')),
  add constraint washer_cycles_off_queue_reason_iff
    check ((off_queue is true) = (off_queue_reason is not null));
comment on column public.washer_cycles.off_queue is
  'Owner 2026-11-09: true when the start was not the queue''s next item for this washer (judged by start_washer_load under the area lock: the queue had a next item and the start took no queue item or a different group). false = the queue''s next, or nothing was queued for the washer. null = not judged (rows before 2026-11-09, non-tap sources). Frozen after insert.';
comment on column public.washer_cycles.off_queue_reason is
  'Owner 2026-11-09: why an off-queue start ran (not_ready | wrong_washer | urgent | other); set exactly when off_queue is true. Not a person: taps stay anonymous. Frozen after insert.';
-- Clients read washer_cycles through column grants (20261104201022); these two carry no identity.
grant select (off_queue, off_queue_reason) on public.washer_cycles to authenticated;

create index washer_cycles_off_queue_day_idx on public.washer_cycles (plant_id, production_date)
  where off_queue and voided_at is null;

create function app.freeze_off_queue()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.off_queue is distinct from old.off_queue or new.off_queue_reason is distinct from old.off_queue_reason then
    raise exception 'VALIDATION_FAILED' using detail = 'off_queue / off_queue_reason: set when the load starts; never changed';
  end if;
  return new;
end;
$$;
comment on function app.freeze_off_queue() is
  'Owner 2026-11-09: BEFORE UPDATE OF off_queue, off_queue_reason on washer_cycles: they never change after insert (corrections are void + re-enter). Internal.';
revoke all on function app.freeze_off_queue() from public, anon, authenticated;
create trigger washer_cycles_freeze_off_queue before update of off_queue, off_queue_reason on public.washer_cycles
  for each row execute function app.freeze_off_queue();

-- ── start_washer_load: + p_off_queue_reason (one signature) ───────────────
drop function public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean);

create function public.start_washer_load(
  p_machine_id        uuid,
  p_client_id         uuid,
  p_queue_item_id     uuid default null,
  p_wash_group_id     uuid default null,
  p_tapped_at         timestamptz default null,
  p_confirm_running   boolean default false,
  p_off_queue_reason  text default null)
returns public.washer_load_result
language plpgsql security definer set search_path = '' as $function$
declare
  v_m         record;
  v_q         public.queue_items;
  v_next      record;
  v_group     uuid;
  v_cycle     uuid;
  v_need      int;
  v_now       timestamptz := pg_catalog.now();
  v_ts        timestamptz;
  v_down      timestamptz;
  v_existing  record;
  v_end       timestamptz;
  v_off_queue boolean;
begin
  -- Role check FIRST: a missing machine and another tenant's machine give the same answer.
  select m.id, m.org_id, m.plant_id, m.area_id, m.kind, m.active into v_m from public.machines m where m.id = p_machine_id;
  if v_m.id is null or not app.has_role(v_m.plant_id, '{owner,manager,lead}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'start_washer_load requires owner, manager or lead on the washer''s plant';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  -- Idempotency before the time window, the reason check and the running guard: an offline retry of a
  -- tap that was already saved returns it.
  select w.id, w.plant_id into v_existing from public.washer_cycles w where w.client_id = p_client_id;
  if v_existing.id is not null then
    if v_existing.plant_id = v_m.plant_id then
      return app.washer_load_result(v_existing.id, true);   -- idempotent retry: nothing advances twice
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  if p_off_queue_reason is not null
     and p_off_queue_reason not in ('not_ready', 'wrong_washer', 'urgent', 'other') then
    raise exception 'VALIDATION_FAILED' using detail = 'p_off_queue_reason: not_ready, wrong_washer, urgent or other';
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
  -- what the queue has next, the running guard below).
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

  -- Owner 2026-11-09: what the queue had next for this washer (its top open assigned item, else the area's
  -- top open unassigned item), before this tap changes anything. Same rule as 20261107003625.
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

  -- Owner 2026-11-09: off-queue = the queue had a next item for this washer and this start is not it (no
  -- queue item, or another group). Nothing queued for the washer → not off-queue (no reason asked).
  v_off_queue := v_next.id is not null
                 and (v_q.id is null or v_q.wash_group_id is distinct from v_next.wash_group_id);
  if v_off_queue and p_off_queue_reason is null then
    -- The caller has owner/manager/lead on this plant (checked above) and can read the queue anyway.
    raise exception 'OFF_QUEUE_REASON_REQUIRED' using detail = 'p_off_queue_reason: required (not the queue''s next for this washer); expected_wash_group_id='
      || v_next.wash_group_id::text;
  end if;

  -- Owner 2026-11-06: a washer still running at the tap time needs an explicit confirmation.
  -- Checked after every other refusal, so a confirmed retry cannot fail on something else first.
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
                                         is_rewash, queue_item_id, off_queue, off_queue_reason)
  select v_m.org_id, v_m.plant_id, v_m.area_id, v_m.id, v_group, g.wash_formula_id,
         app.shift_instance_at(v_m.area_id, v_ts), v_ts, 1, 'manual', (select auth.uid()), p_client_id,
         coalesce(v_q.is_rewash, false), v_q.id,
         v_off_queue, case when v_off_queue then p_off_queue_reason end
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
$function$;
comment on function public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean, text) is
  'F1/D1 RPC (owner/manager/lead; NO staff session, owner decision 2026-11-02): one tap = one load started on an active washer, at p_tapped_at (the device time of an offline tap; default now; must be within [now − 30 min, now + 1 min], else OUT_OF_RANGE_TIMESTAMP). A washer marked down at that time refuses the tap (MACHINE_DOWN); a washer that is down now accepts only a tap at least 60 s before its down event (security review L1). Picks p_queue_item_id, else the top open item assigned to this washer, else the top open unassigned item of the area (limited to p_wash_group_id when given), else an off-queue load of p_wash_group_id. Owner 2026-11-09: a start that is not the queue''s next for this washer (the queue had a next item for it, i.e. the top open assigned item, else the area''s top open unassigned item, judged under the area lock before the tap, and the start took no queue item or another group) needs p_off_queue_reason (not_ready | wrong_washer | urgent | other), else OFF_QUEUE_REASON_REQUIRED (detail ends with expected_wash_group_id=<uuid>); with nothing queued for the washer no reason is asked (off_queue false); a reason sent for an on-queue start is ignored; the skipped item is untouched. Stored as washer_cycles.off_queue / off_queue_reason (no tapper identity). Owner 2026-11-06: a washer still RUNNING at the tap time (a live, non-voided cycle of it with started_at + its formula''s cycle_minutes after the tap time — the get_washroom_board rule; a cycle with unknown cycle time never blocks) refuses the tap with WASHER_RUNNING (detail names the expected end in UTC) unless p_confirm_running = true; checked last, under the area lock, so it is race-safe. Writes washer_cycles (source manual, load_count 1, started_at = tap time, group, group''s formula, is_rewash from the queue item, the area''s shift at the tap time, production_date; load_factor_used and customer_id by trigger) and advances the queue item (loads_started+1; queued→in_progress; done at loads_needed). No alert. Idempotent on p_client_id, checked before the time window, the reason check and the running guard, and again under the lock (duplicate=true, nothing advances twice). Errors: NOT_AUTHORIZED, VALIDATION_FAILED, OUT_OF_RANGE_TIMESTAMP, MACHINE_DOWN, OFF_QUEUE_REASON_REQUIRED, WASHER_RUNNING.';
revoke all on function public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean, text) from public, anon;
grant execute on function public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean, text) to authenticated, service_role;

-- ── Owner-only: today's off-queue starts by reason ────────────────────────
create function public.get_off_queue_starts(
  p_plant_id        uuid,
  p_production_date date default null)
returns table (reason text, starts integer, loads numeric, last_at timestamptz, by_wash_group jsonb)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_p    record;
  v_date date;
begin
  select p.id, p.timezone, p.production_day_start into v_p from public.plants p where p.id = p_plant_id;
  if v_p.id is null or not app.has_role(v_p.id, '{owner}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_off_queue_starts requires owner on the plant';
  end if;
  v_date := coalesce(p_production_date, app.production_date(pg_catalog.now(), v_p.timezone, v_p.production_day_start));
  return query
  with c as (
    select w.off_queue_reason as r, w.wash_group_id, w.load_count * w.load_factor_used as std, w.started_at
      from public.washer_cycles w
     where w.plant_id = v_p.id
       and w.production_date = v_date
       and w.off_queue
       and w.voided_at is null
  ), g as (
    select c.r, c.wash_group_id, count(*)::int as n, sum(c.std) as l
      from c group by c.r, c.wash_group_id
  )
  select k.r, coalesce(t.n, 0), coalesce(t.l, 0::numeric), t.la,
         coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                     'wash_group_id', g.wash_group_id, 'wash_group_name', wg.name,
                     'wash_group_name_i18n', wg.name_i18n, 'starts', g.n, 'loads', g.l)
                     order by g.n desc, wg.name)
                     from g
                     left join public.wash_groups wg on wg.id = g.wash_group_id and wg.plant_id = v_p.id
                    where g.r = k.r), '[]'::jsonb)
    from unnest(array['not_ready', 'wrong_washer', 'urgent', 'other']) with ordinality as k(r, o)
    left join (select c.r, count(*)::int as n, sum(c.std) as l, max(c.started_at) as la
                 from c group by c.r) t on t.r = k.r
   order by k.o;
end;
$$;
comment on function public.get_off_queue_starts(uuid, date) is
  'Owner 2026-11-09 read (OWNER only; definer, role check first, else NOT_AUTHORIZED): the plant''s off-queue washer starts (washer_cycles.off_queue, not voided) of p_production_date (default: the current production day, 12:00→12:00 plant-local), one row per reason, always all four in order not_ready, wrong_washer, urgent, other: starts (count), loads (standard loads = load_count × load_factor_used), last_at (latest started_at, null when none), by_wash_group (jsonb [{wash_group_id, wash_group_name, wash_group_name_i18n, starts, loads}], most starts first). No person identity: washer taps are anonymous. Dashboard count only; no push, no alert.';
revoke all on function public.get_off_queue_starts(uuid, date) from public, anon;
grant execute on function public.get_off_queue_starts(uuid, date) to authenticated, service_role;
