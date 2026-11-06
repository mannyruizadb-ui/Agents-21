-- "Entered by" names on OWNER screens only (owner 2026-11-06: "I need to see the names of the manager
-- inputting info, for accountability"). This reverses the 2026-11-04 "no names anywhere" decision for
-- owner-role callers ONLY. Every other role gets null in the name columns (or is refused by an owner-only
-- read). Who-entered columns stay hidden from direct client table reads (column grants unchanged), names
-- come only through these definer reads, and nothing totals, counts or ranks by person.
--
-- Name rule (app.person_name): the entry-staff display name for PIN-attributed rows (staff_id), else the
-- account's profiles.full_name, else the account's username (the email's local part).
--
-- Owner reads that now carry names (null for non-owners):
--   get_queue            + created_by_name (who added the queue item, e.g. a manager's rewash). NOT
--                          updated_by: a washer START tap bumps the item, so it would name the tapper
--                          (taps carry no name, owner 2026-11-02).
--   get_machine_status   + status_by_name (who marked the current status: down or fixed).
--   get_load_out_board   routes[].loaded_by_name (who marked it loaded); lines[].entered_by_name (who
--                          last typed the line; new column load_out_lines.entered_by, null for older rows).
-- New owner-only reads (NOT_AUTHORIZED for every other role):
--   get_soil_estimate_entries      estimates with entered_by_name
--   get_finished_goods_entries     finished-goods entries with entered_by_name / voided_by_name
--   get_machine_status_history     machine down / fixed events with entered_by_name
-- Tasks (created_by / done_by / reviewed_by names) are in 20261106123654_add_task_review.
-- Deliberately NOT named: washer_cycles (taps carry no name or PIN, owner 2026-11-02: per-washman loads
-- would be per-worker output) and shift_crew_hours (HR/legal hold). audit_log and app.audit() untouched.

-- ── Name helper ───────────────────────────────────────────────────────────
create function app.person_name(p_user uuid, p_staff uuid, p_plant uuid)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select s.display_name from public.entry_staff s where s.id = p_staff and s.plant_id = p_plant),
    (select coalesce(nullif(pg_catalog.btrim(pr.full_name), ''), pg_catalog.split_part(u.email, '@', 1))
       from auth.users u left join public.profiles pr on pr.user_id = u.id
      where u.id = p_user));
$$;
comment on function app.person_name(uuid, uuid, uuid) is
  'Owner 2026-11-06 (owner screens only): display name for an entry: the entry staff''s display_name when p_staff is set (same plant), else profiles.full_name of p_user, else the username (email local part); null when neither. Internal: callers must check the OWNER role first and pass null names to everyone else.';
revoke all on function app.person_name(uuid, uuid, uuid) from public, anon, authenticated;

-- ── get_queue + created_by_name ───────────────────────────────────────────
drop function public.get_queue(uuid);
create function public.get_queue(p_area_id uuid)
returns table (
  org_id uuid, plant_id uuid, area_id uuid, id uuid, "position" numeric(30,15), is_rush boolean,
  status app.queue_status, qty numeric(10,2), unit app.qty_unit, qty_loads numeric, approximate boolean,
  wash_group_id uuid, wash_group_name text, wash_group_name_i18n jsonb, wash_group_color_hex text,
  item_type_id uuid, item_name text, item_name_i18n jsonb, item_color_hex text, note text, version integer,
  started_at timestamptz, created_at timestamptz, assigned_machine_id uuid, assigned_machine_name text,
  is_rewash boolean, loads_started integer, loads_needed integer, loads_remaining integer,
  created_by_name text)
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
         case when v_owner then app.person_name(q.created_by, null, q.plant_id) end
    from public.queue_board b
    join public.queue_items q on q.id = b.id and q.plant_id = b.plant_id
   where b.area_id = v_area.id and b.plant_id = v_area.plant_id
   order by b.is_rush desc, b."position", b.id;
end;
$$;
comment on function public.get_queue(uuid) is
  'C1–C4 read (owner/manager/lead/viewer on the plant, or a display of this area; definer, role check first): the area''s open queue in board order (rush first, then position). Columns = queue_board (incl. loads_started / loads_needed / loads_remaining) + created_by_name (owner 2026-11-06: who added the item; OWNER callers only, null for every other role). Errors: NOT_AUTHORIZED.';
revoke all on function public.get_queue(uuid) from public, anon;
grant execute on function public.get_queue(uuid) to authenticated, service_role;

-- ── get_machine_status + status_by_name ───────────────────────────────────
drop function public.get_machine_status(uuid);
create function public.get_machine_status(p_plant_id uuid)
returns table (machine_id uuid, machine_name text, kind app.machine_kind, area_id uuid, area_name text, active boolean,
               status app.machine_status, reason text, since timestamptz, server_time timestamptz, reason_code text,
               reason_label_i18n jsonb, status_by_name text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_plant  uuid;
  v_reason boolean;
  v_owner  boolean;
begin
  select p.id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant is null or not app.has_role(v_plant, '{owner,manager,lead,viewer}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_machine_status requires a role on the plant';
  end if;
  v_reason := app.has_role(v_plant, '{owner,manager}');   -- L6: free-text reasons for owner/manager only
  v_owner  := app.has_role(v_plant, '{owner}');           -- names: owner only (2026-11-06)
  return query
  select m.id, m.name, m.kind, m.area_id, a.name, m.active,
         coalesce(e.status, 'up'::app.machine_status), case when v_reason then e.reason end, e.occurred_at, pg_catalog.now(),
         case when v_reason then e.reason_code end,
         case when v_reason then e.label_i18n end,
         case when v_owner and e.status is not null then app.person_name(e.entered_by, null, m.plant_id) end
    from public.machines m
    join public.areas a on a.id = m.area_id and a.plant_id = m.plant_id
    left join lateral (
      select x.status, x.reason, x.reason_code, x.occurred_at, x.entered_by, r.label_i18n from public.machine_status_events x
        left join public.machine_down_reasons r on r.plant_id = x.plant_id and r.code = x.reason_code
       where x.machine_id = m.id and x.plant_id = m.plant_id
       order by x.occurred_at desc, x.seq desc limit 1) e on true
   where m.plant_id = v_plant
     and (m.active or e.status = 'down')
   order by a.name, m.kind, m.name, m.id;
end;
$$;
comment on function public.get_machine_status(uuid) is
  'Owner 2026-11-04 read (owner/manager/lead/viewer of the plant; definer, role check first): one row per active machine of every kind (plus inactive machines still marked down), with area, status (down|up; up when never marked), since (when the current status began; null = never went down), server_time for data age, and the latest event''s reason_code (preset, translated by the client), reason_label_i18n and reason (details) — owner/manager only, null for lead/viewer (security review L6). status_by_name (owner 2026-11-06): who marked the current status (down or fixed), for OWNER callers only, null for every other role. Errors: NOT_AUTHORIZED.';
revoke all on function public.get_machine_status(uuid) from public, anon;
grant execute on function public.get_machine_status(uuid) to authenticated, service_role;

-- ── Load-out: who typed a line ────────────────────────────────────────────
alter table public.load_out_lines add column entered_by uuid references auth.users(id);
create index load_out_lines_entered_by_idx on public.load_out_lines (entered_by);
comment on column public.load_out_lines.entered_by is
  'Owner 2026-11-06: the account that last set this line (set_load_out_line / copy_load_out_from). Never selectable by clients; named on the owner''s load-out board only. Null for lines written before 2026-11-06.';
-- Keep it out of direct client reads: table-wide SELECT becomes column SELECT without entered_by.
revoke all on public.load_out_lines from anon, authenticated;
grant select (id, org_id, plant_id, load_date, route_id, item_type_id, special_text, qty, created_at, updated_at)
  on public.load_out_lines to authenticated;

create or replace function public.set_load_out_line(
  p_plant_id     uuid,
  p_load_date    date,
  p_route_id     uuid,
  p_qty          int,
  p_item_type_id uuid default null,
  p_special_text text default null)
returns public.load_out_lines language plpgsql volatile security definer set search_path = '' as $$
declare
  v_plant record;
  v_route record;
  v_text  text;
  v_today date;
  v_row   public.load_out_lines;
begin
  select p.id, p.org_id, p.timezone into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant.id is null or not app.can_enter_load_out(v_plant.id) then
    raise exception 'NOT_AUTHORIZED' using detail = 'set_load_out_line requires owner, or a manager granted can_enter_load_out';
  end if;
  v_today := (pg_catalog.now() at time zone v_plant.timezone)::date;
  if p_load_date is null or p_load_date < v_today - 7 or p_load_date > v_today + 30 then
    raise exception 'VALIDATION_FAILED' using detail = 'load_date: from 7 days ago to 30 days ahead';
  end if;
  select r.id, r.days_of_week, r.active into v_route from public.routes r where r.id = p_route_id and r.plant_id = v_plant.id;
  if v_route.id is null or not v_route.active then
    raise exception 'VALIDATION_FAILED' using detail = 'route_id: not an active route of this plant';
  end if;
  if not (extract(dow from p_load_date)::smallint = any (v_route.days_of_week)) then
    raise exception 'VALIDATION_FAILED' using detail = 'route_id: this route does not run on that weekday';
  end if;
  if p_qty is null or p_qty < 0 or p_qty > 100000 then
    raise exception 'VALIDATION_FAILED' using detail = 'qty: 0–100,000 (0 = not needed)';
  end if;
  v_text := app.clean_note(p_special_text, 80, 'special_text');
  if (p_item_type_id is null) = (v_text is null) then
    raise exception 'VALIDATION_FAILED' using detail = 'give either an item or a special item text';
  end if;
  if p_item_type_id is not null and not exists (
       select 1 from public.item_types i where i.id = p_item_type_id and i.plant_id = v_plant.id and i.active) then
    raise exception 'VALIDATION_FAILED' using detail = 'item_type_id: no active item with this id in the plant';
  end if;

  if p_item_type_id is not null then
    insert into public.load_out_lines as l (org_id, plant_id, load_date, route_id, item_type_id, qty, entered_by)
    values (v_plant.org_id, v_plant.id, p_load_date, v_route.id, p_item_type_id, p_qty, (select auth.uid()))
    on conflict (plant_id, load_date, route_id, item_type_id) where item_type_id is not null
    do update set qty = excluded.qty, entered_by = excluded.entered_by
    returning l.* into v_row;
  else
    insert into public.load_out_lines as l (org_id, plant_id, load_date, route_id, special_text, qty, entered_by)
    values (v_plant.org_id, v_plant.id, p_load_date, v_route.id, v_text, p_qty, (select auth.uid()))
    on conflict (plant_id, load_date, route_id, lower(special_text)) where special_text is not null
    do update set qty = excluded.qty, special_text = excluded.special_text, entered_by = excluded.entered_by
    returning l.* into v_row;
  end if;
  v_row.entered_by := null;   -- never returned to the client (names: owner board only)
  return v_row;
end;
$$;
comment on function public.set_load_out_line(uuid, date, uuid, int, uuid, text) is
  'Owner 2026-11-06 RPC (owner, or a manager granted can_enter_load_out; definer, permission first): sets one load-out line for p_load_date (plant-local; 7 days back to 30 ahead) and p_route_id (an active route that runs on that weekday): either p_item_type_id (active item; qty in its own count: packs for pack items, pieces for unit items) or p_special_text (1–80 chars) with p_qty (0–100,000; 0 = not needed). Upserts (same date + route + item/text) and records the caller as entered_by (returned as null). Returns the line. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';

create or replace function public.copy_load_out_from(p_plant_id uuid, p_from_date date, p_to_date date)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_plant record;
  v_today date;
  v_n     int;
begin
  select p.id, p.org_id, p.timezone into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant.id is null or not app.can_enter_load_out(v_plant.id) then
    raise exception 'NOT_AUTHORIZED' using detail = 'copy_load_out_from requires owner, or a manager granted can_enter_load_out';
  end if;
  v_today := (pg_catalog.now() at time zone v_plant.timezone)::date;
  if p_from_date is null or p_to_date is null or p_from_date = p_to_date
     or p_to_date < v_today - 7 or p_to_date > v_today + 30 then
    raise exception 'VALIDATION_FAILED' using detail = 'dates: two different dates; the target from 7 days ago to 30 days ahead';
  end if;
  insert into public.load_out_lines (org_id, plant_id, load_date, route_id, item_type_id, special_text, qty, entered_by)
  select l.org_id, l.plant_id, p_to_date, l.route_id, l.item_type_id, l.special_text, l.qty, (select auth.uid())
    from public.load_out_lines l
    join public.routes r on r.id = l.route_id and r.plant_id = l.plant_id and r.active
    left join public.item_types i on i.id = l.item_type_id and i.plant_id = l.plant_id
   where l.plant_id = v_plant.id and l.load_date = p_from_date and l.qty > 0
     and extract(dow from p_to_date)::smallint = any (r.days_of_week)
     and (l.item_type_id is null or i.active)
     and not exists (select 1 from public.load_out_lines t
                      where t.plant_id = l.plant_id and t.load_date = p_to_date and t.route_id = l.route_id
                        and (t.item_type_id = l.item_type_id or lower(t.special_text) = lower(l.special_text)));
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
comment on function public.copy_load_out_from(uuid, date, date) is
  'Owner 2026-11-06 RPC ("same as yesterday"; owner, or a manager granted can_enter_load_out): copies the lines with qty > 0 of p_from_date to p_to_date (7 days back to 30 ahead), only for active routes that run on p_to_date''s weekday and active items, never overwriting a line already set for p_to_date. The caller is recorded as entered_by of the copies. Returns lines copied. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';

create or replace function public.get_load_out_board(p_plant_id uuid, p_load_date date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_p     record;
  v_date  date;
  v_local timestamp;
  v_owner boolean;
begin
  select p.id, p.timezone into v_p from public.plants p where p.id = p_plant_id;
  if v_p.id is null or not app.has_role(v_p.id, '{owner,manager,lead,viewer}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_load_out_board requires a role on the plant';
  end if;
  v_owner := app.has_role(v_p.id, '{owner}');   -- names: owner only (2026-11-06)
  v_local := pg_catalog.now() at time zone v_p.timezone;
  -- Default: the next loading morning (today until noon, then tomorrow).
  v_date := coalesce(p_load_date, case when v_local::time < '12:00' then v_local::date else v_local::date + 1 end);

  return pg_catalog.jsonb_build_object(
    'plant_id', v_p.id,
    'load_date', v_date,
    'routes', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'route_id', r.id, 'name', r.name, 'load_time', r.load_time,
               'loaded', coalesce(ev.loaded, false), 'loaded_since', case when ev.loaded then ev.occurred_at end,
               'loaded_by_name', case when v_owner and ev.loaded then app.person_name(ev.entered_by, null, r.plant_id) end,
               'lines', coalesce((
                 select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                          'line_id', l.id, 'item_type_id', l.item_type_id, 'item_name', i.name, 'item_name_i18n', i.name_i18n,
                          'count_mode', i.count_mode, 'pack_size', i.pack_size, 'special_text', l.special_text, 'qty', l.qty,
                          'entered_by_name', case when v_owner then app.person_name(l.entered_by, null, l.plant_id) end)
                          order by (l.item_type_id is null), i.sort_order, i.name, l.special_text)
                   from public.load_out_lines l
                   left join public.item_types i on i.id = l.item_type_id and i.plant_id = l.plant_id
                  where l.plant_id = r.plant_id and l.route_id = r.id and l.load_date = v_date and l.qty > 0), '[]'::jsonb))
               order by r.load_time, r.sort_order, r.name)
        from public.routes r
        left join lateral (
          select e.loaded, e.occurred_at, e.entered_by from public.route_load_events e
           where e.route_id = r.id and e.plant_id = r.plant_id and e.load_date = v_date
           order by e.occurred_at desc, e.seq desc limit 1) ev on true
       where r.plant_id = v_p.id and r.active
         and extract(dow from v_date)::smallint = any (r.days_of_week)), '[]'::jsonb),
    'totals', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'item_type_id', t.item_type_id, 'item_name', t.name, 'item_name_i18n', t.name_i18n,
               'count_mode', t.count_mode, 'pack_size', t.pack_size, 'qty', t.qty) order by t.sort_order, t.name)
        from (select i.id as item_type_id, i.name, i.name_i18n, i.count_mode, i.pack_size, i.sort_order, sum(l.qty)::int as qty
                from public.load_out_lines l
                join public.routes r on r.id = l.route_id and r.plant_id = l.plant_id and r.active
                join public.item_types i on i.id = l.item_type_id and i.plant_id = l.plant_id
               where l.plant_id = v_p.id and l.load_date = v_date and l.qty > 0
                 and extract(dow from v_date)::smallint = any (r.days_of_week)
               group by i.id) t), '[]'::jsonb),
    'server_time', pg_catalog.now());
end;
$$;
comment on function public.get_load_out_board(uuid, date) is
  'Owner 2026-11-06 read (owner/manager/lead/viewer; definer, role check first): the load-out for p_load_date (default: the next loading morning, plant-local: today before noon, else tomorrow). jsonb {plant_id, load_date, routes[{route_id, name, load_time, loaded, loaded_since, loaded_by_name, lines[{line_id, item_type_id, item_name, item_name_i18n, count_mode, pack_size, special_text, qty, entered_by_name}]}] (only active routes that run on that weekday, by load time), totals[{item_type_id, item_name, item_name_i18n, count_mode, pack_size, qty}] (items only; specials stay per route), server_time}. qty is in the item''s own count (packs for pack items). loaded_by_name / entered_by_name: OWNER callers only (null for every other role; null for lines typed before 2026-11-06). Errors: NOT_AUTHORIZED.';

-- ── Owner-only: soil estimate entries with names ──────────────────────────
create function public.get_soil_estimate_entries(
  p_plant_id      uuid,
  p_since         timestamptz default null,
  p_wash_group_id uuid default null,
  p_limit         int default 100)
returns table (estimate_id uuid, wash_group_id uuid, wash_group_name text, wash_group_name_i18n jsonb,
               qty numeric, unit app.qty_unit, qty_loads numeric, note text, entered_at timestamptz,
               entered_by_name text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_plant uuid;
  v_from  timestamptz;
begin
  select p.id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant is null or not app.has_role(v_plant, '{owner}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_soil_estimate_entries requires owner on the plant';
  end if;
  if p_limit is null or p_limit not between 1 and 500 then
    raise exception 'VALIDATION_FAILED' using detail = 'p_limit: 1–500';
  end if;
  v_from := greatest(coalesce(p_since, pg_catalog.now() - interval '24 hours'), pg_catalog.now() - interval '31 days');
  return query
  select e.id, e.wash_group_id, g.name, g.name_i18n, e.qty, e.unit,
         app.to_loads(e.wash_group_id, null, e.qty, e.unit), e.note, e.entered_at,
         app.person_name(e.entered_by, e.staff_id, e.plant_id)
    from public.soil_estimates e
    join public.wash_groups g on g.id = e.wash_group_id and g.plant_id = e.plant_id
   where e.plant_id = v_plant
     and e.entered_at > v_from
     and (p_wash_group_id is null or e.wash_group_id = p_wash_group_id)
   order by e.entered_at desc, e.id desc
   limit p_limit;
end;
$$;
comment on function public.get_soil_estimate_entries(uuid, timestamptz, uuid, int) is
  'Owner 2026-11-06 read (OWNER only; definer, role check first): the plant''s soil estimates entered after p_since (default 24 hours ago; never more than 31 days back), optionally one wash group, newest first, at most p_limit (1–500, default 100). Columns: estimate_id (matches current_soil_estimates.estimate_id), wash_group_id, wash_group_name, wash_group_name_i18n, qty, unit, qty_loads (app.to_loads; null = no factor), note, entered_at, entered_by_name (entry staff name for PIN entries, else the account name). No per-person totals. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.get_soil_estimate_entries(uuid, timestamptz, uuid, int) from public, anon;
grant execute on function public.get_soil_estimate_entries(uuid, timestamptz, uuid, int) to authenticated, service_role;

-- ── Owner-only: finished-goods entries with names ─────────────────────────
create function public.get_finished_goods_entries(
  p_plant_id        uuid,
  p_production_date date default null,
  p_area_id         uuid default null,
  p_limit           int default 200)
returns table (entry_id uuid, area_id uuid, shift_instance_id uuid, production_date date, item_type_id uuid,
               item_name text, item_name_i18n jsonb, wash_group_id uuid, packs integer, pack_size_used integer,
               loose_pieces integer, pieces integer, occurred_at timestamptz, note text, voided_at timestamptz,
               void_reason text, entered_by_name text, voided_by_name text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_p    record;
  v_date date;
begin
  select p.id, p.timezone, p.production_day_start into v_p from public.plants p where p.id = p_plant_id;
  if v_p.id is null or not app.has_role(v_p.id, '{owner}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_finished_goods_entries requires owner on the plant';
  end if;
  if p_limit is null or p_limit not between 1 and 500 then
    raise exception 'VALIDATION_FAILED' using detail = 'p_limit: 1–500';
  end if;
  v_date := coalesce(p_production_date, app.production_date(pg_catalog.now(), v_p.timezone, v_p.production_day_start));
  return query
  select f.id, f.area_id, f.shift_instance_id, f.production_date, f.item_type_id, i.name, i.name_i18n, f.wash_group_id,
         f.packs, f.pack_size_used, f.loose_pieces, f.pieces, f.occurred_at, f.note, f.voided_at, f.void_reason,
         app.person_name(f.entered_by, f.staff_id, f.plant_id),
         case when f.voided_at is not null then app.person_name(f.voided_by, null, f.plant_id) end
    from public.finished_goods_entries f
    join public.item_types i on i.id = f.item_type_id and i.plant_id = f.plant_id
   where f.plant_id = v_p.id
     and f.production_date = v_date
     and (p_area_id is null or f.area_id = p_area_id)
   order by f.occurred_at desc, f.id desc
   limit p_limit;
end;
$$;
comment on function public.get_finished_goods_entries(uuid, date, uuid, int) is
  'Owner 2026-11-06 read (OWNER only; definer, role check first): the plant''s finished-goods entries (voided ones included, with voided_at / void_reason) for p_production_date (default: the current production day, 12:00→12:00 plant-local), optionally one area, newest first, at most p_limit (1–500, default 200). pieces is the stored generated column. entered_by_name: entry staff name for PIN entries, else the account name; voided_by_name: who voided it. No per-person totals. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.get_finished_goods_entries(uuid, date, uuid, int) from public, anon;
grant execute on function public.get_finished_goods_entries(uuid, date, uuid, int) to authenticated, service_role;

-- ── Owner-only: machine down / fixed history with names ───────────────────
create function public.get_machine_status_history(
  p_plant_id   uuid,
  p_since      timestamptz default null,
  p_machine_id uuid default null,
  p_limit      int default 100)
returns table (event_id uuid, machine_id uuid, machine_name text, kind app.machine_kind, area_id uuid,
               status app.machine_status, reason_code text, reason_label_i18n jsonb, reason text,
               occurred_at timestamptz, entered_by_name text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_plant uuid;
  v_from  timestamptz;
begin
  select p.id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant is null or not app.has_role(v_plant, '{owner}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_machine_status_history requires owner on the plant';
  end if;
  if p_limit is null or p_limit not between 1 and 500 then
    raise exception 'VALIDATION_FAILED' using detail = 'p_limit: 1–500';
  end if;
  v_from := greatest(coalesce(p_since, pg_catalog.now() - interval '7 days'), pg_catalog.now() - interval '31 days');
  return query
  select e.id, m.id, m.name, m.kind, m.area_id, e.status, e.reason_code, r.label_i18n, e.reason, e.occurred_at,
         app.person_name(e.entered_by, null, e.plant_id)
    from public.machine_status_events e
    join public.machines m on m.id = e.machine_id and m.plant_id = e.plant_id
    left join public.machine_down_reasons r on r.plant_id = e.plant_id and r.code = e.reason_code
   where e.plant_id = v_plant
     and e.occurred_at > v_from
     and (p_machine_id is null or e.machine_id = p_machine_id)
   order by e.occurred_at desc, e.seq desc
   limit p_limit;
end;
$$;
comment on function public.get_machine_status_history(uuid, timestamptz, uuid, int) is
  'Owner 2026-11-06 read (OWNER only; definer, role check first): machine down / fixed events after p_since (default 7 days ago; never more than 31 days back), optionally one machine, newest first, at most p_limit (1–500, default 100). Columns: event_id, machine_id, machine_name, kind, area_id, status (down|up = fixed), reason_code, reason_label_i18n, reason (details), occurred_at, entered_by_name (who marked it). No per-person totals. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.get_machine_status_history(uuid, timestamptz, uuid, int) from public, anon;
grant execute on function public.get_machine_status_history(uuid, timestamptz, uuid, int) to authenticated, service_role;
