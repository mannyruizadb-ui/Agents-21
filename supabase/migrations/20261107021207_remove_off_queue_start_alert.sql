-- Remove the off_queue_start alert kind (owner 2026-11-07: "not wanted"; it was a misunderstanding).
--
-- off_queue_start was added in 20261107003625 (an owner information alert written by start_washer_load
-- when a load was off the queue or not the group the queue had next). It never reached the cloud (the cloud
-- is at 20261106133543 and this migration ships in the same deploy), so no alert_events row and no
-- memberships.alert_levels key with it can exist there. Removed everywhere:
--   * start_washer_load no longer computes "what the queue had next" nor writes the alert (the tap itself
--     is unchanged);
--   * app.owner_alert_kinds / app.push_alert_kinds / app.alert_level_default / app.alert_payload drop it;
--   * memberships.alert_levels: default and allowed keys without it (any stored key is stripped first);
--   * alert_events kind CHECK without it.
-- History (only possible in a local/dev database that ran 20261107003625): rows are NOT deleted
-- (append-only alerts). The new kind CHECK is added NOT VALID and validated only when no such row exists,
-- so such a database still migrates; app.alert_visible_to already shows only kinds listed in
-- app.owner_alert_kinds, so any leftover row is hidden from the Alerts tab and never pushed.

-- ── start_washer_load: no off_queue_start ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.start_washer_load(p_machine_id uuid, p_client_id uuid, p_queue_item_id uuid DEFAULT NULL::uuid, p_wash_group_id uuid DEFAULT NULL::uuid, p_tapped_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_confirm_running boolean DEFAULT false)
 RETURNS public.washer_load_result
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
$function$;
comment on function public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean) is
  'F1/D1 RPC (owner/manager/lead; NO staff session, owner decision 2026-11-02): one tap = one load started on an active washer, at p_tapped_at (the device time of an offline tap; default now; must be within [now − 30 min, now + 1 min], else OUT_OF_RANGE_TIMESTAMP). A washer marked down at that time refuses the tap (MACHINE_DOWN); a washer that is down now accepts only a tap at least 60 s before its down event (security review L1). Owner 2026-11-06: a washer still RUNNING at the tap time (a live, non-voided cycle of it with started_at + its formula''s cycle_minutes after the tap time — the get_washroom_board rule; a cycle with unknown cycle time never blocks) refuses the tap with WASHER_RUNNING (detail names the expected end in UTC) unless p_confirm_running = true; checked under the area lock, so it is race-safe. Picks p_queue_item_id, else the top open item assigned to this washer, else the top open unassigned item of the area (limited to p_wash_group_id when given), else an off-queue load of p_wash_group_id. Writes washer_cycles (source manual, load_count 1, started_at = tap time, group, group''s formula, is_rewash from the queue item, the area''s shift at the tap time, production_date; load_factor_used and customer_id (the group''s customer, 2026-11-06) by trigger) and advances the queue item (loads_started+1; queued→in_progress; done at loads_needed). No alert (off_queue_start removed 2026-11-07). Idempotent on p_client_id, checked before the time window and the running guard, and again under the lock (duplicate=true, nothing advances twice). Errors: NOT_AUTHORIZED, VALIDATION_FAILED, OUT_OF_RANGE_TIMESTAMP, MACHINE_DOWN, WASHER_RUNNING.';

-- ── Kind lists and defaults ───────────────────────────────────────────────
create or replace function app.owner_alert_kinds()
returns text[] language sql immutable set search_path = '' as $$
  select array['customer_delivery', 'estimate_entered', 'rewash_added', 'account_locked'];
$$;
comment on function app.owner_alert_kinds() is
  'Owner 2026-11-06 (C): the owner information alert kinds that have a per-owner level (push | quiet | off): customer_delivery, estimate_entered, rewash_added, account_locked (2026-11-07). off_queue_start removed 2026-11-07.';

create or replace function app.alert_level_default(p_kind text)
returns text language sql immutable set search_path = '' as $$
  select case p_kind when 'customer_delivery' then 'push'
                     when 'estimate_entered' then 'quiet'
                     when 'rewash_added' then 'quiet'
                     when 'account_locked' then 'push' end;
$$;
comment on function app.alert_level_default(text) is
  'Owner 2026-11-06 (C): default level per owner alert kind: customer_delivery and account_locked (2026-11-07) push; estimate_entered and rewash_added quiet; null for other kinds.';

create or replace function app.push_alert_kinds()
returns text[] language sql immutable set search_path = '' as $$
  select array['machine_down', 'washer_idle', 'task_assigned', 'task_done', 'route_loaded',
               'customer_delivery', 'estimate_entered', 'rewash_added', 'account_locked'];
$$;
comment on function app.push_alert_kinds() is
  'Owner 2026-11-06: alert_events kinds shown in the Alerts tab and delivered by Web Push to their push recipients (owner information kinds, account_locked included, only to owners whose level is push). off_queue_start removed 2026-11-07.';

-- ── memberships.alert_levels without off_queue_start ──────────────────────
alter table public.memberships drop constraint memberships_alert_levels_ok;
update public.memberships m
   set alert_levels = m.alert_levels - 'off_queue_start'
 where m.alert_levels ? 'off_queue_start';
-- The default also as an internal function, for the self-only guard (20261107021209). The column default
-- stays a literal (no client EXECUTE needed on an app helper); a pgTAP test keeps the two equal.
create function app.default_alert_levels()
returns jsonb language sql immutable set search_path = '' as $$
  select '{"customer_delivery": "push", "estimate_entered": "quiet", "rewash_added": "quiet"}'::jsonb;
$$;
comment on function app.default_alert_levels() is
  'Owner 2026-11-06 (C): memberships.alert_levels default (kinds not listed use app.alert_level_default: account_locked push). off_queue_start removed 2026-11-07. Internal.';
revoke all on function app.default_alert_levels() from public, anon, authenticated;
alter table public.memberships
  alter column alert_levels set default '{"customer_delivery": "push", "estimate_entered": "quiet", "rewash_added": "quiet"}'::jsonb,
  add constraint memberships_alert_levels_ok check (
    jsonb_typeof(alert_levels) = 'object'
    and (alert_levels - '{customer_delivery,estimate_entered,rewash_added,account_locked}'::text[]) = '{}'::jsonb
    and not jsonb_path_exists(alert_levels, '$.* ? (@.type() != "string" || (@ != "push" && @ != "quiet" && @ != "off"))'));

-- ── alert_events kind CHECK without off_queue_start ───────────────────────
alter table public.alert_events
  drop constraint alert_events_kind_check,
  add constraint alert_events_kind_check check (kind in ('estimate_stale', 'device_offline', 'import_failed',
    'shift_generation_failed', 'machine_down', 'washer_idle', 'task_assigned', 'task_done', 'route_loaded',
    'customer_delivery', 'estimate_entered', 'rewash_added', 'account_locked')) not valid;
do $$
begin
  if not exists (select 1 from public.alert_events a where a.kind = 'off_queue_start') then
    alter table public.alert_events validate constraint alert_events_kind_check;
  else
    raise notice 'alert_events keeps its off_queue_start history rows; the kind CHECK stays NOT VALID for them';
  end if;
end;
$$;

-- ── alert_payload: no off_queue_start branch (everything else unchanged from 20261107010613) ──
CREATE OR REPLACE FUNCTION app.alert_payload(p_alert public.alert_events)
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
    -- The batch: estimates the same account recorded on the plant within 10 minutes of the FIRST one (the
    -- alert's subject; its recorded_at, else the alert's sent_at for rows from before recorded_at). The
    -- account is only used to group; it is never in the payload.
    select pg_catalog.jsonb_build_object(
             'first_estimate_id', f.id,
             'count', (select count(*) from public.soil_estimates e
                        where e.plant_id = f.plant_id and e.entered_by = f.entered_by
                          and e.recorded_at >= coalesce(f.recorded_at, p_alert.sent_at)
                          and e.recorded_at < coalesce(f.recorded_at, p_alert.sent_at) + interval '10 minutes'),
             'estimates', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                                      'estimate_id', e.id, 'wash_group_id', g.id, 'wash_group_name', g.name,
                                      'wash_group_name_i18n', g.name_i18n, 'customer_id', g.customer_id,
                                      'qty', e.qty, 'unit', e.unit,
                                      'qty_loads', app.to_loads(e.wash_group_id, null, e.qty, e.unit),
                                      'entered_at', e.entered_at) order by e.recorded_at, e.id)
                                      from public.soil_estimates e
                                      join public.wash_groups g on g.id = e.wash_group_id and g.plant_id = e.plant_id
                                     where e.plant_id = f.plant_id and e.entered_by = f.entered_by
                                       and e.recorded_at >= coalesce(f.recorded_at, p_alert.sent_at)
                                       and e.recorded_at < coalesce(f.recorded_at, p_alert.sent_at) + interval '10 minutes'), '[]'::jsonb))
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
  elsif p_alert.kind = 'account_locked' then
    -- 2026-11-07: a security event for owners. The username IS the subject (mapped accounts only; an
    -- owner's own email is never shown). No IP, no typed values, no password detail.
    select pg_catalog.jsonb_build_object(
             'user_id', u.id, 'username', app.login_username(u.email),
             'failures', (select s.max_attempts from app.sign_in_limits() s where s.kind = 'login'),
             'locked_until', pg_catalog.to_timestamp(p_alert.dedupe_key::bigint),
             'still_locked', exists (select 1 from public.sign_in_lockouts l
                                      where l.key_hash = app.sign_in_key('login', u.email)
                                        and l.locked_until > pg_catalog.now()))
      into v
      from auth.users u
     where u.id = p_alert.subject_id and p_alert.dedupe_key ~ '^[0-9]{1,12}$';
  end if;
  return coalesce(v, '{}'::jsonb);
end;
$function$;
comment on function app.alert_payload(public.alert_events) is
  'Owner 2026-11-06: what an alert may show, per kind (jsonb; no free text except a task''s own text to its assignees/owners; never names or notes, except account_locked''s username for owners). machine_down: machine, area, reason_code + label, down_since, still_down. washer_idle: machine, area, idle_since, still_idle. route_loaded: route, load_time, load_date, loaded_at. task_assigned / task_done: task_id, body, to_on_duty, created_at, reminder, done_at, reviewed_at. customer_delivery: delivery_id, customer, delivered_at, voided, total_bins, lines[group, bins, loads]. estimate_entered: first_estimate_id, count, estimates[group, customer_id, qty, unit, qty_loads, entered_at] (the batch window starts at the first estimate''s recorded_at). rewash_added: queue item, area, group, customer_id, qty, unit, qty_loads, status, created_at. account_locked (2026-11-07): user_id, username (mapped accounts only, else null), failures, locked_until, still_locked. off_queue_start removed 2026-11-07 (empty payload). Internal.';
