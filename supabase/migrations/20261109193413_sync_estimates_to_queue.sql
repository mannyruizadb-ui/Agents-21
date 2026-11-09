-- Estimates fill the washroom queue (owner decision 2026-11-09, option a): a dirty-work estimate of one
-- of OUR wash groups keeps one "from estimates" queue item in the plant's washroom queue, so the owner
-- only reorders items and assigns washers. This is an owner-approved exception to "queue edits are owner
-- only" (20261104163711): the estimate's author (owner or manager, record_soil_estimate's role check,
-- unchanged) creates / updates / cancels that one item through the estimate.
--
-- 1. queue_items.from_estimate boolean not null default false (readable by authenticated, column grant;
--    written only by the definer code below). A partial UNIQUE index keeps at most ONE open
--    (queued / in_progress) estimate item per (area, wash group).
-- 2. app.sync_estimate_queue_item(estimate id): internal (revoked from every client role). Rules:
--    * Only our own groups (wash_groups.customer_id is null, active): AA Linen keeps its delivery flow.
--      Only when the plant has exactly ONE active washroom area (else no sync, the estimate still saves).
--    * Only the group's CURRENT estimate drives the queue (current_soil_estimates' order: entered_at desc,
--      id desc). A late offline estimate older than one already recorded changes nothing.
--    * The estimate is what is still out there dirty (it excludes loads already in washers).
--    * Runs under the area's queue lock ('queue:<area>', as every queue writer), in the caller's
--      transaction.
--    * No open estimate item:  qty > 0 → INSERT at the BOTTOM of the normal items (not rush, not rewash,
--      unassigned, no note), qty / unit = the estimate's, from_estimate = true, created_by = the
--      estimate's entered_by, client_id = a fresh uuid. qty 0 → nothing.
--    * Open item, not started (loads_started = 0): qty > 0 → qty / unit := the estimate's, in place
--      (position, rush, assigned washer, note, rewash flag all kept); qty 0 → cancelled.
--    * Open item, in progress (loads_started > 0):
--        qty 0 → qty := loads_started, unit 'load' → done (loads_needed = loads_started).
--        qty > 0 with a conversion (app.to_loads not null) → qty := loads_started + estimate loads,
--          unit 'load' (rounded UP to 2 decimals, which never changes ceil(); capped at 100,000).
--        qty > 0 WITHOUT a conversion (basket / bin and the group has no factor) → qty / unit := the
--          estimate's own qty / unit. Rationale: adding baskets to loads, or keeping the item's unit with
--          the estimate's number, would be a guessed conversion (never allowed). With that unit the item's
--          loads_needed is null, so start-taps keep counting but never auto-complete it; the owner or a
--          manager closes it by hand (set_queue_item_status), as for any item without a factor.
--      If the new loads_needed ≤ loads_started, the item is marked done (same rule as update_queue_item).
--    * An unchanged qty / unit writes nothing (no version bump, no audit row).
--    Every write goes through the normal triggers: app.bump_queue_version (version + 1, updated_by,
--    started_at / completed_at) so clients refetch on the version / Realtime change, and app.audit.
--    Manual, rewash and customer items (from_estimate = false) are never touched.
-- 3. record_soil_estimate: same signature, contract and return; calls the sync after the insert and the
--    alert. The idempotent retry (same client_id) returns before the insert, so it never syncs twice.
-- 4. get_queue: + from_estimate (last column) for a small "from estimates" tag.
-- 4b. undo_washer_load (security review 2026-11-09, Medium): an undo never reopens a done estimate item while
--     a newer open estimate item of the same (area, group) exists (it would break the unique index); the
--     cycle is still voided and the old item still gets loads_started − 1 (stays done).
-- 5. Backfill (app.backfill_estimate_queue_items(), internal, re-runnable): every group's current estimate with qty > 0 for our own active groups and no
--    open estimate item gets one (cloud 2026-11-09: Black mats 1 basket, Colored mats 1 basket). Runs as
--    postgres; created_by = the estimate's entered_by; the audit trigger records a null actor.

-- ── 1. Column + one open estimate item per (area, group) ──────────────────
alter table public.queue_items add column from_estimate boolean not null default false;
comment on column public.queue_items.from_estimate is
  'Owner 2026-11-09: true = the item is kept in sync with the wash group''s current dirty-work estimate (record_soil_estimate → app.sync_estimate_queue_item). At most one open per (area, wash group). Never set by a client.';
grant select (from_estimate) on public.queue_items to authenticated;
create unique index queue_items_one_open_estimate_idx on public.queue_items (area_id, wash_group_id)
  where from_estimate and status in ('queued', 'in_progress');

-- ── 2. Sync helper ────────────────────────────────────────────────────────
create function app.sync_estimate_queue_item(p_estimate_id uuid)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare
  v_e     public.soil_estimates;
  v_g     record;
  v_area  uuid;
  v_areas int;
  v_q     public.queue_items;
  v_loads numeric;
  v_qty   numeric;
  v_unit  app.qty_unit;
  v_need  int;
begin
  select e.* into v_e from public.soil_estimates e where e.id = p_estimate_id;
  if v_e.id is null then
    return null;
  end if;
  select g.id, g.active, g.customer_id into v_g
    from public.wash_groups g where g.id = v_e.wash_group_id and g.plant_id = v_e.plant_id;
  if v_g.id is null or not v_g.active or v_g.customer_id is not null then
    return null;                                   -- customer (AA) groups keep their delivery flow
  end if;
  select count(*), min(a.id::text)::uuid into v_areas, v_area
    from public.areas a where a.plant_id = v_e.plant_id and a.kind = 'washroom' and a.active;
  if v_areas <> 1 then
    return null;
  end if;

  -- Serialize with every queue writer of the area (positions, the one-open-item rule).
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('queue:' || v_area::text, 0));

  -- Only the group's current estimate (current_soil_estimates order) drives the queue. Read after the
  -- lock, so a concurrent estimate of the same group committed first is seen.
  if exists (select 1 from public.soil_estimates e
              where e.plant_id = v_e.plant_id and e.wash_group_id = v_e.wash_group_id and e.id <> v_e.id
                and (e.entered_at > v_e.entered_at or (e.entered_at = v_e.entered_at and e.id > v_e.id))) then
    return null;
  end if;

  select q.* into v_q from public.queue_items q
   where q.area_id = v_area and q.plant_id = v_e.plant_id and q.wash_group_id = v_e.wash_group_id
     and q.from_estimate and q.status in ('queued', 'in_progress')
   for update;

  if v_q.id is null then
    if v_e.qty <= 0 then
      return null;
    end if;
    insert into public.queue_items as q (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position,
                                         is_rush, note, created_by, client_id, assigned_machine_id, is_rewash, from_estimate)
    values (v_e.org_id, v_e.plant_id, v_area, v_e.wash_group_id, null, v_e.qty, v_e.unit,
            app.queue_edge_position(v_area, false, false, null),
            false, null, v_e.entered_by, gen_random_uuid(), null, false, true)
    returning q.* into v_q;
    return v_q.id;
  end if;

  if v_q.loads_started = 0 then
    if v_e.qty <= 0 then
      update public.queue_items q set status = 'cancelled' where q.id = v_q.id;
      return v_q.id;
    end if;
    v_qty := v_e.qty;
    v_unit := v_e.unit;
  elsif v_e.qty <= 0 then
    v_qty := v_q.loads_started;
    v_unit := 'load';
  else
    v_loads := app.to_loads(v_e.wash_group_id, null, v_e.qty, v_e.unit);
    if v_loads is null then
      v_qty := v_e.qty;                            -- no factor: never add baskets to loads (see header)
      v_unit := v_e.unit;
    else
      v_qty := least(pg_catalog.ceil((v_q.loads_started + v_loads) * 100) / 100, 100000);
      v_unit := 'load';
    end if;
  end if;

  if v_q.qty is distinct from v_qty or v_q.unit is distinct from v_unit then
    update public.queue_items q set qty = v_qty, unit = v_unit where q.id = v_q.id returning q.* into v_q;
  end if;
  v_need := app.queue_loads_needed(v_q.wash_group_id, v_q.item_type_id, v_q.qty, v_q.unit);
  if v_q.status = 'in_progress' and v_need is not null and v_q.loads_started >= v_need then
    update public.queue_items q set status = 'done' where q.id = v_q.id;
  end if;
  return v_q.id;
end;
$$;
comment on function app.sync_estimate_queue_item(uuid) is
  'Owner 2026-11-09 (estimates fill the queue): keeps the ONE open from_estimate queue item of the estimate''s wash group in the plant''s only active washroom area in step with the group''s CURRENT estimate (latest entered_at, then id). Our own active groups only (customer_id null). Under the area queue lock. No item + qty > 0 → insert at the bottom of the normal items (estimate qty/unit, created_by = entered_by). Not started → qty/unit in place (position, rush, washer, note kept); qty 0 → cancelled. In progress → qty = loads_started + estimate loads in ''load'' (estimate qty/unit when the unit has no factor); qty 0 → qty = loads_started → done. Unchanged values write nothing. Returns the queue item id (null = nothing to do). Internal: the caller checks the role.';
revoke all on function app.sync_estimate_queue_item(uuid) from public, anon, authenticated;

-- ── 3. record_soil_estimate: sync the queue after the insert ──────────────
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
  -- Idempotent retry: returns the saved row BEFORE the insert and the queue sync, so a retry never
  -- syncs the queue twice.
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
  -- Owner 2026-11-09: the estimate fills the washroom queue (same transaction, under the queue lock;
  -- lock order batch → queue, and no queue writer takes the batch lock).
  perform app.sync_estimate_queue_item(v_row.id);
  return v_row;
end;
$function$;

comment on function public.record_soil_estimate(uuid, numeric, app.qty_unit, uuid, uuid, text, timestamptz) is
  'B1 RPC (owner/manager; no entry PIN since 2026-11-07: entered_by = the account, staff_id null, p_staff_session_id ignored): appends a soil estimate for a wash group (never updates; 0 = cleared). qty 0–10,000 (2 decimals; e.g. 2.75 bins) in load, or basket / bin when the group allows it; note ≤ 280; p_entered_at = the device time of an offline entry (default now; within [now − 6 h, now + 1 min], else OUT_OF_RANGE_TIMESTAMP). Owner 2026-11-06: the first estimate of an entry batch (one account, one plant, 10 minutes from the batch''s first recorded_at) writes an estimate_entered owner alert; the batch lock is taken before the insert and recorded_at = clock_timestamp() under it (2026-11-07), so a racing estimate is always in its batch. Owner 2026-11-09: for our own groups (not a customer''s), the group''s CURRENT estimate keeps one from_estimate washroom queue item in step (app.sync_estimate_queue_item: create at the bottom / update qty in place / cancel at 0 / in progress = loads started + estimate loads, done at 0), an owner-approved exception to owner-only queue edits. Idempotent on p_client_id, checked before the time window (returns the existing row; no second alert, no second queue sync). Returns the soil_estimates row. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, OUT_OF_RANGE_TIMESTAMP.';

-- ── 4. get_queue + from_estimate ──────────────────────────────────────────
drop function public.get_queue(uuid);
create function public.get_queue(p_area_id uuid)
returns table (
  org_id uuid, plant_id uuid, area_id uuid, id uuid, "position" numeric(30,15), is_rush boolean,
  status app.queue_status, qty numeric(10,2), unit app.qty_unit, qty_loads numeric, approximate boolean,
  wash_group_id uuid, wash_group_name text, wash_group_name_i18n jsonb, wash_group_color_hex text,
  item_type_id uuid, item_name text, item_name_i18n jsonb, item_color_hex text, note text, version integer,
  started_at timestamptz, created_at timestamptz, assigned_machine_id uuid, assigned_machine_name text,
  is_rewash boolean, loads_started integer, loads_needed integer, loads_remaining integer,
  created_by_name text, from_estimate boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_area  record;
  v_owner boolean;
begin
  select a.id, a.plant_id into v_area from public.areas a where a.id = p_area_id;
  if v_area.id is null
     or not (app.has_role(v_area.plant_id, '{owner,manager,lead,viewer}')
             or (app.is_display(v_area.plant_id) and (app.my_device()).area_id = v_area.id)) then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_queue requires a role on the area''s plant, or a display of this area';
  end if;
  v_owner := app.has_role(v_area.plant_id, '{owner}');
  return query
  select b.org_id, b.plant_id, b.area_id, b.id, b."position", b.is_rush, b.status, b.qty, b.unit, b.qty_loads,
         b.approximate, b.wash_group_id, b.wash_group_name, b.wash_group_name_i18n, b.wash_group_color_hex,
         b.item_type_id, b.item_name, b.item_name_i18n, b.item_color_hex, b.note, b.version, b.started_at,
         b.created_at, b.assigned_machine_id, b.assigned_machine_name, b.is_rewash, b.loads_started,
         b.loads_needed, b.loads_remaining,
         case when v_owner then app.person_name(q.created_by, null, q.plant_id) end,
         q.from_estimate
    from public.queue_board b
    join public.queue_items q on q.id = b.id and q.plant_id = b.plant_id
   where b.area_id = v_area.id and b.plant_id = v_area.plant_id
   order by b.is_rush desc, b."position", b.id;
end;
$$;
comment on function public.get_queue(uuid) is
  'C1–C4 read (owner/manager/lead/viewer on the plant, or a display of this area; definer, role check first): the area''s open queue in board order (rush first, then position). Columns = queue_board (incl. loads_started / loads_needed / loads_remaining) + created_by_name (owner 2026-11-06: who added the item; OWNER callers only, null for every other role) + from_estimate (owner 2026-11-09: the item is kept in step with the group''s dirty-work estimate). Errors: NOT_AUTHORIZED.';
revoke all on function public.get_queue(uuid) from public, anon;
grant execute on function public.get_queue(uuid) to authenticated, service_role;

-- ── 4b. undo_washer_load: never reopen a done estimate item next to a newer one ──
-- Security review 2026-11-09 (Medium): a start completes a from_estimate item (done); within the 5-minute
-- undo window a new estimate opens a NEW estimate item for the group; an UNDO of that start would reopen
-- the old item (done → in_progress) and hit queue_items_one_open_estimate_idx (23505), so the undo failed.
-- Now: the cycle is still voided and the old item still gets its load back (loads_started − 1), but it
-- STAYS DONE when another open from_estimate item of the same (area, wash group) exists: the new item is
-- the current estimate of what is still dirty. Everything else is identical to 20261106133543 (role check
-- first, idempotency, 5-minute window, area queue lock, reopen-only-what-this-tap-changed).
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
    -- Owner 2026-11-09 / security review: a done estimate item is not reopened while a newer open
    -- estimate item of the same (area, group) exists (one open estimate item per group).
    if v_q.status = 'done' and v_status <> 'done' and v_q.from_estimate
       and exists (select 1 from public.queue_items o
                    where o.area_id = v_q.area_id and o.plant_id = v_q.plant_id and o.wash_group_id = v_q.wash_group_id
                      and o.from_estimate and o.status in ('queued', 'in_progress') and o.id <> v_q.id) then
      v_status := 'done';
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
  'F1 RPC (owner/manager/lead): undoes a manual washer tap within 5 minutes of when it was recorded (created_at; owner 2026-11-06, was 30 minutes; an offline tap''s started_at can be earlier). VOIDS the cycle (voided_at/by, void_reason = p_reason or ''undo''; excluded from every report; never deleted) and gives the load back to its queue item (loads_started−1; reopens done → in_progress, or in_progress → queued, only if this tap made that change). 2026-11-09: a done from_estimate item is NOT reopened when another open from_estimate item of the same area and wash group exists (it keeps status done; the load is still given back). Already voided → returns it (duplicate=true). Errors: NOT_AUTHORIZED, OUT_OF_RANGE_TIMESTAMP, VALIDATION_FAILED.';

-- ── 5. Backfill: current estimates > 0 of our own active groups ───────────
create function app.backfill_estimate_queue_items()
returns int language plpgsql volatile security definer set search_path = '' as $$
declare
  r   record;
  v_n int := 0;
begin
  for r in
    select c.id
      from (select distinct on (e.plant_id, e.wash_group_id) e.id, e.plant_id, e.wash_group_id, e.qty
              from public.soil_estimates e
             order by e.plant_id, e.wash_group_id, e.entered_at desc, e.id desc) c
      join public.wash_groups g on g.id = c.wash_group_id and g.plant_id = c.plant_id
     where c.qty > 0 and g.active and g.customer_id is null
       and not exists (select 1 from public.queue_items q
                        where q.plant_id = c.plant_id and q.wash_group_id = c.wash_group_id
                          and q.from_estimate and q.status in ('queued', 'in_progress'))
     order by c.plant_id, g.sort_order, g.name, c.id
  loop
    if app.sync_estimate_queue_item(r.id) is not null then
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;
comment on function app.backfill_estimate_queue_items() is
  'Owner 2026-11-09, one-off (migration 20261109193413; re-runnable): for every wash group''s CURRENT estimate with qty > 0, of our own active groups, with no open from_estimate queue item, creates one through app.sync_estimate_queue_item (bottom of the normal items, in group sort order). Returns how many were created; a re-run creates none. Internal.';
revoke all on function app.backfill_estimate_queue_items() from public, anon, authenticated;

do $$
begin
  raise notice 'sync_estimates_to_queue backfill: % estimate queue item(s) created', app.backfill_estimate_queue_items();
end;
$$;
