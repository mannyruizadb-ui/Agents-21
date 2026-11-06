-- Queue editing is owner-only, with two manager exceptions (owner 2026-11-04, rounds 2 and 3).
-- Supersedes the {owner,manager} rule of 20261103212040_create_queue_rpcs.sql:
--   * owner: everything (create, reorder, update, cancel), as before.
--   * manager, exception 1 (update_queue_item): move a load OFF a washer that is down (marked down in
--     machine_status_events, or deactivated) to another active washer that is not down, or to
--     unassigned (next free washer). Every other field must be sent unchanged.
--   * manager, exception 2 (create_queue_item): add a REWASH item (finishing sends goods back): never
--     RUSH, never assigned to a washer, lands at the bottom of the normal items, qty in load, basket or
--     bin.
--   * anything else by a manager: NOT_AUTHORIZED (reorder and cancel are owner-only).
-- set_queue_item_status (owner/manager/lead) and get_queue are unchanged; leads and viewers keep what
-- they had (no queue edits).
--
-- No oracle: the item / area is looked up by id and the caller's role on ITS plant is checked first
-- (owner or manager; missing and foreign ids give the same NOT_AUTHORIZED). The manager exceptions
-- are then judged on the locked row, before the version check, so a manager never learns more than
-- the queue rows RLS already lets them read.

-- ── create_queue_item ─────────────────────────────────────────────────────
create or replace function public.create_queue_item(
  p_area_id             uuid,
  p_qty                 numeric,
  p_unit                app.qty_unit,
  p_client_id           uuid,
  p_wash_group_id       uuid default null,
  p_item_type_id        uuid default null,
  p_is_rush             boolean default false,
  p_note                text default null,
  p_assigned_machine_id uuid default null,
  p_is_rewash           boolean default false)
returns public.queue_items language plpgsql volatile security definer set search_path = '' as $$
declare
  v_area  record;
  v_group uuid;
  v_item_group uuid;
  v_note  text;
  v_row   public.queue_items;
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
  if v_row.id is null then   -- a concurrent retry won the race
    select q.* into v_row from public.queue_items q where q.client_id = p_client_id and q.plant_id = v_area.plant_id;
    if v_row.id is null then
      raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
    end if;
  end if;
  return v_row;
end;
$$;
comment on function public.create_queue_item(uuid, numeric, app.qty_unit, uuid, uuid, uuid, boolean, text, uuid, boolean) is
  'C1 RPC (owner; manager only for a rewash: p_is_rewash true, not rush, no washer, unit load|basket|bin — anything else NOT_AUTHORIZED, owner 2026-11-04; no staff session): adds work to an area''s queue. p_wash_group_id or p_item_type_id (item must be in the group; the group defaults to the item''s); qty 0.01–100,000 in load|basket|bin|piece|pack (piece/pack need an item, pack a pack item); note ≤ 140; RUSH → top of the rush items, else bottom of the normal items; p_assigned_machine_id = an active washer of the area that is not down (null = next free washer); p_is_rewash only in a washroom area. Idempotent on p_client_id (returns the existing row). Returns the queue_items row. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, COUNT_MODE_MISMATCH, MACHINE_DOWN.';

-- ── reorder_queue_item: owner only ────────────────────────────────────────
create or replace function public.reorder_queue_item(p_id uuid, p_expected_version int, p_after_id uuid default null)
returns public.queue_items language plpgsql volatile security definer set search_path = '' as $$
declare
  v       public.queue_items;
  v_after numeric;
  v_next  numeric;
  v_pos   numeric;
begin
  v := app.lock_queue_item(p_id, p_expected_version, '{owner}');
  if v.status not in ('queued', 'in_progress') then
    raise exception 'VALIDATION_FAILED' using detail = 'status: only open items can be moved';
  end if;
  if p_after_id = p_id then
    raise exception 'VALIDATION_FAILED' using detail = 'p_after_id: cannot be the item itself';
  end if;

  for i in 1..2 loop
    if p_after_id is null then
      v_pos := app.queue_edge_position(v.area_id, v.is_rush, true, v.id);
      exit;
    end if;
    select q.position into v_after from public.queue_items q
     where q.id = p_after_id and q.plant_id = v.plant_id and q.area_id = v.area_id
       and q.is_rush = v.is_rush and q.status in ('queued', 'in_progress');
    if v_after is null then
      raise exception 'VALIDATION_FAILED' using detail = 'p_after_id: not an open item of the same area and rush group';
    end if;
    select min(q.position) into v_next from public.queue_items q
     where q.area_id = v.area_id and q.is_rush = v.is_rush and q.status in ('queued', 'in_progress')
       and q.id <> v.id and q.position > v_after;
    if v_next is null then
      v_pos := v_after + 1;
      exit;
    elsif v_next - v_after >= 0.000001 then
      v_pos := (v_after + v_next) / 2;
      exit;
    end if;
    -- Gap too small: renumber the partition 1..n (bumps those versions), then compute again.
    update public.queue_items q set position = r.n
      from (select q2.id, row_number() over (order by q2.position, q2.id) as n
              from public.queue_items q2
             where q2.area_id = v.area_id and q2.is_rush = v.is_rush and q2.status in ('queued', 'in_progress')) r
     where q.id = r.id and q.position <> r.n;
  end loop;

  update public.queue_items q set position = v_pos where q.id = v.id returning q.* into v;
  return v;
end;
$$;
comment on function public.reorder_queue_item(uuid, int, uuid) is
  'C2 RPC (owner only, owner 2026-11-04): moves an open queue item directly below p_after_id (open, same area, same RUSH partition), or to the top of its partition when p_after_id is null. Midpoint positions; the partition is renumbered when the gap < 1e-6. Returns the queue_items row (new position, version). Errors: NOT_AUTHORIZED, QUEUE_VERSION_CONFLICT, VALIDATION_FAILED.';

-- ── update_queue_item: owner; manager only to move a load off a down washer ──
create or replace function public.update_queue_item(
  p_id                  uuid,
  p_expected_version    int,
  p_qty                 numeric,
  p_unit                app.qty_unit,
  p_is_rush             boolean,
  p_is_rewash           boolean,
  p_note                text default null,
  p_assigned_machine_id uuid default null)
returns public.queue_items language plpgsql volatile security definer set search_path = '' as $$
declare
  v       public.queue_items;
  v_kind  app.area_kind;
  v_note  text;
  v_pos   numeric;
  v_need  int;
begin
  select q.* into v from public.queue_items q where q.id = p_id;
  if v.id is null or not app.has_role(v.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'update_queue_item requires owner (or manager, moving a load off a down washer) on the item''s plant';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('queue:' || v.area_id::text, 0));
  select q.* into v from public.queue_items q where q.id = p_id for update;

  -- Manager exception 1: only the assignment changes, and only away from a washer that is down
  -- (marked down now, or deactivated). The target is validated below like any assignment.
  if not app.has_role(v.plant_id, '{owner}')
     and not coalesce(v.assigned_machine_id is not null
              and p_assigned_machine_id is distinct from v.assigned_machine_id
              and (app.machine_is_down_at(v.assigned_machine_id, v.plant_id, pg_catalog.now())
                   or not exists (select 1 from public.machines m
                                   where m.id = v.assigned_machine_id and m.plant_id = v.plant_id and m.active))
              and p_qty = v.qty and p_unit = v.unit
              and p_is_rush = v.is_rush and p_is_rewash = v.is_rewash
              and nullif(pg_catalog.btrim(p_note), '') is not distinct from v.note, false) then
    raise exception 'NOT_AUTHORIZED' using detail = 'managers may only move a load off a washer that is down (send every other field unchanged)';
  end if;

  if p_expected_version is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_expected_version: required';
  end if;
  if v.version <> p_expected_version then
    raise exception 'QUEUE_VERSION_CONFLICT' using detail = format('expected %s, found %s', p_expected_version, v.version);
  end if;
  if v.status not in ('queued', 'in_progress') then
    raise exception 'VALIDATION_FAILED' using detail = 'status: done or cancelled items cannot be edited';
  end if;
  perform app.check_queue_qty_unit(v.plant_id, v.item_type_id, p_qty, p_unit);
  v_note := app.clean_note(p_note, 140, 'note');
  if p_is_rush is null or p_is_rewash is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_is_rush, p_is_rewash: not null';
  end if;
  select a.kind into v_kind from public.areas a where a.id = v.area_id;
  if p_is_rewash and v_kind <> 'washroom' then
    raise exception 'VALIDATION_FAILED' using detail = 'is_rewash: only washroom work can be a rewash';
  end if;
  if p_assigned_machine_id is distinct from v.assigned_machine_id then
    perform app.check_assignable_washer(p_assigned_machine_id, v.plant_id, v.area_id);
  end if;
  -- C3: toggling RUSH moves the item to the top of its new partition.
  v_pos := case when p_is_rush is distinct from v.is_rush
                then app.queue_edge_position(v.area_id, p_is_rush, true, v.id) else v.position end;

  update public.queue_items q
     set qty = p_qty, unit = p_unit, is_rush = p_is_rush, is_rewash = p_is_rewash, note = v_note,
         assigned_machine_id = p_assigned_machine_id, position = v_pos
   where q.id = v.id
  returning q.* into v;

  -- A smaller quantity can make an item that start-taps already covered complete.
  v_need := app.queue_loads_needed(v.wash_group_id, v.item_type_id, v.qty, v.unit);
  if v.status = 'in_progress' and v_need is not null and v.loads_started >= v_need then
    update public.queue_items q set status = 'done' where q.id = v.id returning q.* into v;
  end if;
  return v;
end;
$$;
comment on function public.update_queue_item(uuid, int, numeric, app.qty_unit, boolean, boolean, text, uuid) is
  'C1/C3 RPC (owner; a manager may only move a load off a washer that is down — marked down or deactivated — to another active washer that is not down, or to unassigned, sending every other field unchanged; anything else NOT_AUTHORIZED, owner 2026-11-04): replaces the editable fields of an open queue item (send them all): qty + unit, RUSH (toggling moves it to the top of the new partition), rewash (washroom only), note (null clears), assigned washer (null = next free washer; a changed assignment must be an active washer of the area that is not down). An in-progress item whose start-taps already cover the new quantity becomes done. Returns the queue_items row. Errors: NOT_AUTHORIZED, QUEUE_VERSION_CONFLICT, VALIDATION_FAILED, COUNT_MODE_MISMATCH, MACHINE_DOWN.';

-- ── cancel_queue_item: owner only ─────────────────────────────────────────
create or replace function public.cancel_queue_item(p_id uuid, p_expected_version int)
returns public.queue_items language plpgsql volatile security definer set search_path = '' as $$
declare
  v public.queue_items;
begin
  select q.* into v from public.queue_items q where q.id = p_id;
  if v.id is null or not app.has_role(v.plant_id, '{owner}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'cancel_queue_item requires owner on the item''s plant';
  end if;
  if v.status = 'cancelled' then
    return v;      -- idempotent retry
  end if;
  v := app.lock_queue_item(p_id, p_expected_version, '{owner}');
  update public.queue_items q set status = 'cancelled' where q.id = v.id returning q.* into v;  -- done → cancelled raises INVALID_STATUS_TRANSITION
  return v;
end;
$$;
comment on function public.cancel_queue_item(uuid, int) is
  'C4 RPC (owner only, owner 2026-11-04): cancels a queued or in-progress item (never deleted). Already cancelled → returns the row (idempotent). Returns the queue_items row. Errors: NOT_AUTHORIZED, QUEUE_VERSION_CONFLICT, INVALID_STATUS_TRANSITION (done).';
