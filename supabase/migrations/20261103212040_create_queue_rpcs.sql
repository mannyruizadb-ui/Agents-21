-- M2 pilot write path, part 2: work-queue RPCs (PRD C1–C4; §5.3; owner decision 2026-11-03).
-- Queue writes are owner/manager actions from the owner's phone and carry NO staff session
-- (deviation from A8's "queue create/reorder/status need name + PIN", per the 2026-11-03 brief).
--
-- Every RPC: SECURITY DEFINER, search_path '', the queue item / area is looked up by id first and the
-- caller's role on ITS plant is checked before anything else, so a missing id and another tenant's id
-- give the same NOT_AUTHORIZED (no cross-tenant oracle). Every other reference (wash group, item,
-- machine, neighbor item) is looked up by id AND the caller's plant (AND area): not found is one
-- VALIDATION_FAILED for foreign and missing ids alike. Writes are audited by queue_items_audit.
--
-- Ordering model (existing columns): the board orders by is_rush desc, position asc, so RUSH items
-- and normal items are two partitions of one area's open (queued/in_progress) items. position is
-- fractional (numeric(30,15)); a move takes the midpoint of its new neighbors, and the partition is
-- renumbered 1..n when the gap is < 1e-6 (renumbering bumps those items' versions: clients refetch).
-- Optimistic concurrency: every change to an existing item takes p_expected_version and raises
-- QUEUE_VERSION_CONFLICT when it differs from version (bumped by app.bump_queue_version).

-- ── Internal helpers (definer RPCs call them as the owner; no client EXECUTE) ──
create function app.clean_note(p_note text, p_max int, p_field text)
returns text language plpgsql immutable set search_path = '' as $$
declare
  v text := nullif(pg_catalog.btrim(p_note), '');
begin
  if v is not null and (pg_catalog.char_length(v) > p_max or v ~ '[[:cntrl:]]') then
    raise exception 'VALIDATION_FAILED' using detail = format('%s: at most %s characters, no control characters', p_field, p_max);
  end if;
  return v;
end;
$$;
comment on function app.clean_note(text, int, text) is
  '§4.9 text rule for RPC arguments: trims, empty → null; longer than p_max or control characters → VALIDATION_FAILED (detail names p_field).';
revoke all on function app.clean_note(text, int, text) from public, anon, authenticated;

create function app.check_qty(p_qty numeric, p_min numeric, p_max numeric, p_field text)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if p_qty is null or p_qty < p_min or p_qty > p_max or p_qty <> pg_catalog.round(p_qty, 2) then
    raise exception 'VALIDATION_FAILED' using detail = format('%s: between %s and %s, at most 2 decimals', p_field, p_min, p_max);
  end if;
end;
$$;
comment on function app.check_qty(numeric, numeric, numeric, text) is
  '§4.9 numeric argument rule for RPCs: not null, p_min ≤ qty ≤ p_max, at most 2 decimals; else VALIDATION_FAILED.';
revoke all on function app.check_qty(numeric, numeric, numeric, text) from public, anon, authenticated;

-- Position at the top (p_top) or bottom of one partition (area + is_rush) of open items, ignoring p_exclude.
create function app.queue_edge_position(p_area_id uuid, p_is_rush boolean, p_top boolean, p_exclude uuid)
returns numeric language sql stable set search_path = '' as $$
  select case when p_top then coalesce(min(q.position), 1) - 1 else coalesce(max(q.position), 0) + 1 end
    from public.queue_items q
   where q.area_id = p_area_id
     and q.is_rush = p_is_rush
     and q.status in ('queued', 'in_progress')
     and q.id is distinct from p_exclude;
$$;
comment on function app.queue_edge_position(uuid, boolean, boolean, uuid) is
  'C1–C3: position just above the first (p_top) or below the last open item of the area''s rush or normal partition, excluding p_exclude.';
revoke all on function app.queue_edge_position(uuid, boolean, boolean, uuid) from public, anon, authenticated;

-- Locks the item for update after the role check. Raises NOT_AUTHORIZED (missing or no role) or
-- QUEUE_VERSION_CONFLICT. Returns the locked row.
create function app.lock_queue_item(p_id uuid, p_expected_version int, p_roles app.member_role[])
returns public.queue_items language plpgsql volatile set search_path = '' as $$
declare
  v public.queue_items;
begin
  select q.* into v from public.queue_items q where q.id = p_id;
  if v.id is null or not app.has_role(v.plant_id, p_roles) then
    raise exception 'NOT_AUTHORIZED' using detail = 'queue item not found, or the caller lacks the role on its plant';
  end if;
  -- Serialize position changes per area, then lock the row.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('queue:' || v.area_id::text, 0));
  select q.* into v from public.queue_items q where q.id = p_id for update;
  if p_expected_version is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_expected_version: required';
  end if;
  if v.version <> p_expected_version then
    raise exception 'QUEUE_VERSION_CONFLICT' using detail = format('expected %s, found %s', p_expected_version, v.version);
  end if;
  return v;
end;
$$;
comment on function app.lock_queue_item(uuid, int, app.member_role[]) is
  'M2 queue RPC prologue: role check on the item''s plant FIRST (missing/foreign → NOT_AUTHORIZED), per-area advisory lock, row lock, then p_expected_version vs version (QUEUE_VERSION_CONFLICT).';
revoke all on function app.lock_queue_item(uuid, int, app.member_role[]) from public, anon, authenticated;

-- Validates an assignment target: an ACTIVE washer of the item's own area (and plant). Unchanged
-- assignments are not re-validated, so an item already on a washer that broke can still be edited.
create function app.check_assignable_washer(p_machine_id uuid, p_plant_id uuid, p_area_id uuid)
returns void language plpgsql stable set search_path = '' as $$
begin
  if p_machine_id is not null and not exists (
       select 1 from public.machines m
        where m.id = p_machine_id and m.plant_id = p_plant_id and m.area_id = p_area_id
          and m.kind = 'washer' and m.active) then
    raise exception 'VALIDATION_FAILED' using detail = 'assigned_machine_id: not an active washer of this area';
  end if;
end;
$$;
comment on function app.check_assignable_washer(uuid, uuid, uuid) is
  'M2: p_machine_id (if set) must be an active washer of p_area_id in p_plant_id; one VALIDATION_FAILED for foreign, missing, inactive or non-washer machines.';
revoke all on function app.check_assignable_washer(uuid, uuid, uuid) from public, anon, authenticated;

-- Shared quantity/unit rules for create and update.
create function app.check_queue_qty_unit(p_plant_id uuid, p_item_type_id uuid, p_qty numeric, p_unit app.qty_unit)
returns void language plpgsql stable set search_path = '' as $$
begin
  perform app.check_qty(p_qty, 0.01, 100000, 'qty');
  if p_unit is null then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: required';
  end if;
  if p_unit in ('piece', 'pack') and p_item_type_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: piece and pack quantities need an item';
  end if;
  if p_unit = 'pack' and exists (select 1 from public.item_types i
                                  where i.id = p_item_type_id and i.plant_id = p_plant_id and i.count_mode <> 'pack') then
    raise exception 'COUNT_MODE_MISMATCH' using detail = 'unit pack: the item is counted by unit';
  end if;
end;
$$;
comment on function app.check_queue_qty_unit(uuid, uuid, numeric, app.qty_unit) is
  'M2 queue rules: qty 0.01–100,000 (2 decimals); piece/pack need an item; pack needs a pack-counted item (COUNT_MODE_MISMATCH).';
revoke all on function app.check_queue_qty_unit(uuid, uuid, numeric, app.qty_unit) from public, anon, authenticated;

-- ── create_queue_item (C1) ────────────────────────────────────────────────
create function public.create_queue_item(
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
    raise exception 'NOT_AUTHORIZED' using detail = 'create_queue_item requires owner or manager on the area''s plant';
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
  'C1 RPC (owner/manager; no staff session): adds work to an area''s queue. p_wash_group_id or p_item_type_id (item must be in the group; the group defaults to the item''s); qty 0.01–100,000 in load|basket|piece|pack (piece/pack need an item, pack a pack item); note ≤ 140; RUSH → top of the rush items, else bottom of the normal items; p_assigned_machine_id = an active washer of the area (null = next free washer); p_is_rewash only in a washroom area. Idempotent on p_client_id (returns the existing row). Returns the queue_items row. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, COUNT_MODE_MISMATCH.';
revoke all on function public.create_queue_item(uuid, numeric, app.qty_unit, uuid, uuid, uuid, boolean, text, uuid, boolean) from public, anon;
grant execute on function public.create_queue_item(uuid, numeric, app.qty_unit, uuid, uuid, uuid, boolean, text, uuid, boolean) to authenticated, service_role;

-- ── reorder_queue_item (C2) ───────────────────────────────────────────────
-- Moves the item directly below p_after_id (an open item of the same area and the same RUSH
-- partition), or to the top of its partition when p_after_id is null. Neighbor-based, so a concurrent
-- move of OTHER items never puts this one in a surprising place; the moved item's version guards it.
create function public.reorder_queue_item(p_id uuid, p_expected_version int, p_after_id uuid default null)
returns public.queue_items language plpgsql volatile security definer set search_path = '' as $$
declare
  v       public.queue_items;
  v_after numeric;
  v_next  numeric;
  v_pos   numeric;
begin
  v := app.lock_queue_item(p_id, p_expected_version, '{owner,manager}');
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
  'C2 RPC (owner/manager): moves an open queue item directly below p_after_id (open, same area, same RUSH partition), or to the top of its partition when p_after_id is null. Midpoint positions; the partition is renumbered when the gap < 1e-6. Returns the queue_items row (new position, version). Errors: NOT_AUTHORIZED, QUEUE_VERSION_CONFLICT, VALIDATION_FAILED.';
revoke all on function public.reorder_queue_item(uuid, int, uuid) from public, anon;
grant execute on function public.reorder_queue_item(uuid, int, uuid) to authenticated, service_role;

-- ── update_queue_item (C1/C3, assignment, rewash) ─────────────────────────
-- Full replacement of the editable fields: send every field (the current value when unchanged).
-- p_note null clears the note; p_assigned_machine_id null = next free washer.
create function public.update_queue_item(
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
  v := app.lock_queue_item(p_id, p_expected_version, '{owner,manager}');
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
  'C1/C3 RPC (owner/manager): replaces the editable fields of an open queue item (send them all): qty + unit, RUSH (toggling moves it to the top of the new partition), rewash (washroom only), note (null clears), assigned washer (null = next free washer; a changed assignment must be an active washer of the area). An in-progress item whose start-taps already cover the new quantity becomes done. Returns the queue_items row. Errors: NOT_AUTHORIZED, QUEUE_VERSION_CONFLICT, VALIDATION_FAILED, COUNT_MODE_MISMATCH.';
revoke all on function public.update_queue_item(uuid, int, numeric, app.qty_unit, boolean, boolean, text, uuid) from public, anon;
grant execute on function public.update_queue_item(uuid, int, numeric, app.qty_unit, boolean, boolean, text, uuid) to authenticated, service_role;

-- ── cancel_queue_item (C4) ────────────────────────────────────────────────
create function public.cancel_queue_item(p_id uuid, p_expected_version int)
returns public.queue_items language plpgsql volatile security definer set search_path = '' as $$
declare
  v public.queue_items;
begin
  select q.* into v from public.queue_items q where q.id = p_id;
  if v.id is null or not app.has_role(v.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'cancel_queue_item requires owner or manager on the item''s plant';
  end if;
  if v.status = 'cancelled' then
    return v;      -- idempotent retry
  end if;
  v := app.lock_queue_item(p_id, p_expected_version, '{owner,manager}');
  update public.queue_items q set status = 'cancelled' where q.id = v.id returning q.* into v;  -- done → cancelled raises INVALID_STATUS_TRANSITION
  return v;
end;
$$;
comment on function public.cancel_queue_item(uuid, int) is
  'C4 RPC (owner/manager): cancels a queued or in-progress item (never deleted). Already cancelled → returns the row (idempotent). Returns the queue_items row. Errors: NOT_AUTHORIZED, QUEUE_VERSION_CONFLICT, INVALID_STATUS_TRANSITION (done).';
revoke all on function public.cancel_queue_item(uuid, int) from public, anon;
grant execute on function public.cancel_queue_item(uuid, int) to authenticated, service_role;

-- ── set_queue_item_status (C4: start / complete by hand) ──────────────────
-- Needed once direct UPDATE is revoked: finishing work, and washroom items without a load count
-- (piece/pack, or baskets without a factor), are completed by hand. 'done' on a queued item passes
-- through in_progress. Cancel goes through cancel_queue_item.
create function public.set_queue_item_status(p_id uuid, p_status app.queue_status, p_expected_version int)
returns public.queue_items language plpgsql volatile security definer set search_path = '' as $$
declare
  v public.queue_items;
begin
  v := app.lock_queue_item(p_id, p_expected_version, '{owner,manager,lead}');
  if p_status is null or p_status not in ('in_progress', 'done') then
    raise exception 'VALIDATION_FAILED' using detail = 'p_status: in_progress or done (cancel with cancel_queue_item)';
  end if;
  if v.status = p_status then
    return v;
  end if;
  if p_status = 'done' and v.status = 'queued' then
    update public.queue_items q set status = 'in_progress' where q.id = v.id;
  end if;
  update public.queue_items q set status = p_status where q.id = v.id returning q.* into v;  -- trigger rejects illegal moves
  return v;
end;
$$;
comment on function public.set_queue_item_status(uuid, app.queue_status, int) is
  'C4 RPC (owner/manager/lead): marks a queue item in_progress or done (done from queued passes through in_progress). Same status → returns the row. Returns the queue_items row. Errors: NOT_AUTHORIZED, QUEUE_VERSION_CONFLICT, INVALID_STATUS_TRANSITION, VALIDATION_FAILED.';
revoke all on function public.set_queue_item_status(uuid, app.queue_status, int) from public, anon;
grant execute on function public.set_queue_item_status(uuid, app.queue_status, int) to authenticated, service_role;

-- ── get_queue (read) ──────────────────────────────────────────────────────
-- SECURITY DEFINER (001 guard) with the same access as queue_items RLS: owner/manager/lead/viewer on
-- the plant, or a paired display of THIS area. Missing or foreign area → NOT_AUTHORIZED.
create function public.get_queue(p_area_id uuid)
returns setof public.queue_board language plpgsql stable security definer set search_path = '' as $$
declare
  v_area record;
begin
  select a.id, a.plant_id into v_area from public.areas a where a.id = p_area_id;
  if v_area.id is null
     or not (app.has_role(v_area.plant_id, '{owner,manager,lead,viewer}')
             or (app.is_display(v_area.plant_id) and (app.my_device()).area_id = v_area.id)) then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_queue requires a role on the area''s plant, or a display of this area';
  end if;
  return query
  select b.* from public.queue_board b
   where b.area_id = v_area.id and b.plant_id = v_area.plant_id
   order by b.is_rush desc, b.position, b.id;
end;
$$;
comment on function public.get_queue(uuid) is
  'C1–C4 read (owner/manager/lead/viewer on the plant, or a display of this area; definer, role check first): the area''s open queue in board order (rush first, then position). Rows = queue_board (incl. loads_started / loads_needed / loads_remaining). Errors: NOT_AUTHORIZED.';
revoke all on function public.get_queue(uuid) from public, anon;
grant execute on function public.get_queue(uuid) to authenticated, service_role;
