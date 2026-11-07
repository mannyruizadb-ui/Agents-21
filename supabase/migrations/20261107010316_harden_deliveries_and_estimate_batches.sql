-- Security review of 312ca2e (customers, deliveries, alert levels), follow-ups b, c, e:
--
-- b. record_customer_delivery is throttled: at most 10 NEW deliveries per plant per account in any
--    10 minutes; the 11th raises RATE_LIMITED. Counted under the washroom queue lock the RPC already
--    takes, so concurrent calls cannot overshoot. Idempotent retries return before the count and never
--    count. A refused call rolls back whole (the single-use staff session is not spent).
-- c. customer_deliveries.client_id is unique per plant (plant_id, client_id) instead of globally, so a
--    client_id another tenant used is no longer "already used" (that answer revealed another tenant's
--    ids). Idempotent retries on the same plant still return the saved delivery (duplicate = true). The
--    global unique implied the per-plant one, so the swap cannot fail on existing rows.
-- e. estimate_entered batching is race-free: record_soil_estimate takes the (plant, account) batch lock
--    BEFORE its insert and stamps recorded_at with clock_timestamp() under that lock, so recorded_at
--    is monotonic per (plant, account). The batch test and the alert payload now both use the batch's
--    FIRST estimate's recorded_at as the window anchor ([first, first + 10 min)), instead of the alert's
--    sent_at (= the transaction start of the first estimate, which a racing estimate could precede and
--    so fall out of the count). Rows from before 20261107003625 (recorded_at null) fall back to sent_at.

-- ── c. client_id unique per plant ─────────────────────────────────────────
alter table public.customer_deliveries drop constraint customer_deliveries_client_id_key;
alter table public.customer_deliveries
  add constraint customer_deliveries_plant_client_id_key unique (plant_id, client_id);
comment on constraint customer_deliveries_plant_client_id_key on public.customer_deliveries is
  'Security review 2026-11-07 (c): client_id is unique per plant, so idempotency never reveals another tenant''s ids.';

-- Throttle lookups: this account's recent deliveries on the plant.
create index customer_deliveries_plant_entered_by_created_idx
  on public.customer_deliveries (plant_id, entered_by, created_at desc);

-- ── b + c. record_customer_delivery ───────────────────────────────────────
create or replace function public.record_customer_delivery(
  p_plant_id         uuid,
  p_customer_id      uuid,
  p_lines            jsonb,
  p_client_id        uuid,
  p_staff_session_id uuid,
  p_note             text default null,
  p_entered_at       timestamptz default null)
returns public.customer_delivery_result language plpgsql volatile security definer set search_path = '' as $$
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
  -- Idempotency (per plant) before the time window, the throttle and the staff session: an offline retry
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
  v_staff := app.use_staff_session(p_staff_session_id, v_plant.id);

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
$$;
comment on function public.record_customer_delivery(uuid, uuid, jsonb, uuid, uuid, text, timestamptz) is
  'Owner 2026-11-06 (B) RPC (owner or manager of the plant + staff session = name + PIN, A8; definer, role check first, no oracle): records an outside customer''s delivery. p_lines: 1–30 {wash_group_id, bins}: active wash groups of p_customer_id (an active customer of the plant), each once, bins 0.25–50 in quarters. p_note ≤ 200. p_entered_at = delivered_at (device time of an offline entry; default now; within [now − 6 h, now + 1 min], else OUT_OF_RANGE_TIMESTAMP). Throttle (security review 2026-11-07): at most 10 new deliveries per plant per account in 10 minutes, else RATE_LIMITED (counted under the queue lock; retries never count). Writes customer_deliveries + customer_delivery_lines (loads = app.to_loads, null without loads_per_bin) and, per line, one washroom queue item at the BOTTOM of the normal items (unit bin, qty = bins, not rush, not rewash, not assigned, customer_id = the customer), then a customer_delivery owner alert. Idempotent on (plant, p_client_id), checked before the time window, the throttle and the session (duplicate = true); a client_id used on another plant is independent (no cross-tenant answer). Returns customer_delivery_result {delivery_id, queue_item_ids (line order), duplicate}. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, OUT_OF_RANGE_TIMESTAMP, STAFF_SESSION_REQUIRED, RATE_LIMITED.';

-- ── e. record_soil_estimate: batch lock before the insert ─────────────────
create or replace function public.record_soil_estimate(p_wash_group_id uuid, p_qty numeric, p_unit app.qty_unit, p_client_id uuid, p_staff_session_id uuid, p_note text default null::text, p_entered_at timestamp with time zone default null::timestamp with time zone)
 returns public.soil_estimates
 language plpgsql
 security definer
 set search_path to ''
as $function$
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
  v_staff := app.use_staff_session(p_staff_session_id, v_g.plant_id);

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
comment on function public.record_soil_estimate(uuid, numeric, app.qty_unit, uuid, uuid, text, timestamptz) is
  'B1 RPC (owner/manager + staff session, A8): appends a soil estimate for a wash group (never updates; 0 = cleared). qty 0–10,000 (2 decimals; e.g. 2.75 bins) in load, or basket / bin when the group allows it; note ≤ 280; p_entered_at = the device time of an offline entry (default now; within [now − 6 h, now + 1 min], else OUT_OF_RANGE_TIMESTAMP). Owner 2026-11-06: the first estimate of an entry batch (one account, one plant, 10 minutes from the batch''s first recorded_at) writes an estimate_entered owner alert; the batch lock is taken before the insert and recorded_at = clock_timestamp() under it (2026-11-07), so a racing estimate is always in its batch. Idempotent on p_client_id, checked before the time window and the session (returns the existing row, even after the single-use session is spent; no second alert). Returns the soil_estimates row. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, OUT_OF_RANGE_TIMESTAMP, STAFF_SESSION_REQUIRED.';

-- ── e. alert_payload: estimate_entered window anchored on the first estimate ──
create or replace function app.alert_payload(p_alert public.alert_events)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
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
  'Owner 2026-11-06: what an alert may show, per kind (jsonb; no free text except a task''s own text to its assignees/owners; never names or notes). machine_down: machine, area, reason_code + label, down_since, still_down. washer_idle: machine, area, idle_since, still_idle. route_loaded: route, load_time, load_date, loaded_at. task_assigned / task_done: task_id, body, to_on_duty, created_at, reminder, done_at, reviewed_at. customer_delivery: delivery_id, customer, delivered_at, voided, total_bins, lines[group, bins, loads]. estimate_entered: first_estimate_id, count, estimates[group, customer_id, qty, unit, qty_loads, entered_at] (the batch window starts at the first estimate''s recorded_at, 2026-11-07). rewash_added: queue item, area, group, customer_id, qty, unit, qty_loads, status, created_at. off_queue_start: cycle, machine, area, group, customer_id, is_rewash, started_at, queue_item_id, off_queue, expected group, voided. Internal.';
