-- Load-out (owner 2026-11-06, B): the drivers' daily load sheet, typed by the office manager or the
-- owner, shown to the supervisor (manager on duty), who marks each route loaded.
--
-- * routes: per plant, name + load time + the weekdays it runs (0 = Sun … 6 = Sat), owner-editable.
--   Seeded for ADB (owner 2026-11-06): Route 21 03:30 Mon/Tue/Thu/Fri; Route 11 04:30 Mon/Thu; Route 5
--   04:30 Tue/Fri; Route 2 05:00 Mon–Fri; Route 4 05:30 Mon/Tue/Thu/Fri. (Wednesday: only Route 2.)
-- * A load-out belongs to a LOAD DATE: the plant-local calendar date the trucks load (03:30–05:30). It
--   shows only the routes that run on that weekday.
-- * load_out_lines: route × item with qty in the item's own count (packs for pack items, e.g. sheets
--   in packs of 10; pieces for unit items, e.g. butcher coats per size M/L/XL), or route × special
--   free text with a qty. Written only by set_load_out_line / copy_load_out_from (owner, or a manager
--   the owner grants memberships.can_enter_load_out: the office manager). qty 0 = not needed.
-- * Soil bags: a new kind of item that is never washed (item_types.washed = false, no wash group),
--   counted in packs of 5. item_types.wash_group_id becomes nullable for non-washed items only.
-- * route_load_events: append-only loaded / not-loaded events (client_id idempotency). The manager on
--   duty (app.managers_on_duty) or an owner marks a route loaded; a loaded event writes alert_events
--   route_loaded (push to the owners).
-- * get_load_out_board: per route (that runs on the date) its lines, loaded state and load time, plus
--   plant totals per item. No per-person data (who typed or who loaded is never returned).

-- ── Non-washed items (soil bags) ──────────────────────────────────────────
alter table public.item_types
  add column washed boolean not null default true,
  alter column wash_group_id drop not null,
  add constraint item_types_washed_has_group check (washed = (wash_group_id is not null));
comment on column public.item_types.washed is
  'Owner 2026-11-06: false for goods that are never washed (soil bags, handed to customers). Non-washed items have no wash group, never enter the washroom queue or reports, and appear only on the load-out.';
grant update (washed) on public.item_types to authenticated;

insert into public.item_types (org_id, plant_id, wash_group_id, name, name_i18n, category, count_mode, pack_size, washed, sort_order)
select p.org_id, p.id, null, 'Soil bags', '{"es":"Bolsas para ropa sucia"}'::jsonb, 'other', 'pack', 5, false, 900
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami'
   and not exists (select 1 from public.item_types i where i.plant_id = p.id and i.name = 'Soil bags');

-- ── Routes ────────────────────────────────────────────────────────────────
create table public.routes (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null,
  plant_id     uuid not null,
  name         text not null check (char_length(name) between 1 and 40 and app.is_clean_text(name)),
  load_time    time not null,
  days_of_week smallint[] not null
               check (cardinality(days_of_week) between 1 and 7 and days_of_week <@ '{0,1,2,3,4,5,6}'::smallint[]),
  sort_order   int not null default 0,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  unique (plant_id, name),
  unique (id, plant_id)
);
alter table public.routes enable row level security;
create index routes_plant_org_idx on public.routes (plant_id, org_id);
comment on table public.routes is
  'Owner 2026-11-06: delivery routes: load time (plant-local) and the weekdays they run (0 = Sun … 6 = Sat). Owner-editable; deactivate, never delete.';
create trigger routes_touch_updated_at before update on public.routes for each row execute function app.touch_updated_at();
create trigger routes_audit after insert or update on public.routes for each row execute function app.audit();
create policy routes_select on public.routes for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')));
create policy routes_insert on public.routes for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner}')));
create policy routes_update on public.routes for update to authenticated
  using ((select app.has_role(plant_id, '{owner}'))) with check ((select app.has_role(plant_id, '{owner}')));
revoke all on public.routes from anon, authenticated;
grant select on public.routes to authenticated;
grant insert (org_id, plant_id, name, load_time, days_of_week, sort_order, active) on public.routes to authenticated;
grant update (name, load_time, days_of_week, sort_order, active) on public.routes to authenticated;

insert into public.routes (org_id, plant_id, name, load_time, days_of_week, sort_order)
select p.org_id, p.id, v.name, v.load_time::time, v.days::smallint[], v.sort_order
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
   ('Route 21', '03:30', '{1,2,4,5}',   10),
   ('Route 11', '04:30', '{1,4}',       20),
   ('Route 5',  '04:30', '{2,5}',       30),
   ('Route 2',  '05:00', '{1,2,3,4,5}', 40),
   ('Route 4',  '05:30', '{1,2,4,5}',   50)) as v(name, load_time, days, sort_order)
 where p.name = 'Miami'
on conflict (plant_id, name) do nothing;

-- ── Who may type the load-out ─────────────────────────────────────────────
alter table public.memberships
  add column can_enter_load_out boolean not null default false,
  add constraint memberships_can_enter_load_out_manager_only check (not can_enter_load_out or role = 'manager');
comment on column public.memberships.can_enter_load_out is
  'Owner 2026-11-06: this manager (the office manager) may type the daily load-out. Owners always may. Set by the owner.';

create function app.can_enter_load_out(p_plant uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select app.password_ok()) and exists (
    select 1 from public.memberships m
    join public.plants p on p.id = p_plant
    where m.user_id = (select auth.uid()) and m.revoked_at is null and m.org_id = p.org_id
      and (m.plant_id is null or m.plant_id = p_plant)
      and (m.role = 'owner' or (m.role = 'manager' and m.can_enter_load_out)));
$$;
comment on function app.can_enter_load_out(uuid) is
  'Owner 2026-11-06: caller is an owner of the plant, or a manager the owner granted can_enter_load_out (password gate applies). Internal.';
revoke all on function app.can_enter_load_out(uuid) from public, anon, authenticated;
grant execute on function app.can_enter_load_out(uuid) to service_role;

-- ── Load-out lines ────────────────────────────────────────────────────────
create table public.load_out_lines (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null,
  plant_id     uuid not null,
  load_date    date not null,
  route_id     uuid not null,
  item_type_id uuid,
  special_text text check (char_length(special_text) between 1 and 80 and app.is_clean_text(special_text)),
  qty          int not null check (qty between 0 and 100000),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (route_id, plant_id) references public.routes(id, plant_id),
  foreign key (item_type_id, plant_id) references public.item_types(id, plant_id),
  constraint load_out_lines_item_or_special check ((item_type_id is null) <> (special_text is null))
);
alter table public.load_out_lines enable row level security;
create index load_out_lines_plant_org_idx on public.load_out_lines (plant_id, org_id);
create index load_out_lines_route_plant_idx on public.load_out_lines (route_id, plant_id);
create index load_out_lines_item_plant_idx on public.load_out_lines (item_type_id, plant_id);
create unique index load_out_lines_item_uq on public.load_out_lines (plant_id, load_date, route_id, item_type_id) where item_type_id is not null;
create unique index load_out_lines_special_uq on public.load_out_lines (plant_id, load_date, route_id, lower(special_text)) where special_text is not null;
comment on table public.load_out_lines is
  'Owner 2026-11-06: the daily load sheet: per load date (the morning the trucks load) and route, an item with qty in its own count (packs for pack items, pieces for unit items) or a special free-text line with a qty. qty 0 = not needed. Written only by set_load_out_line / copy_load_out_from.';
create trigger load_out_lines_touch_updated_at before update on public.load_out_lines for each row execute function app.touch_updated_at();
create trigger load_out_lines_audit after insert or update on public.load_out_lines for each row execute function app.audit();
create policy load_out_lines_select on public.load_out_lines for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')));
revoke all on public.load_out_lines from anon, authenticated;
grant select on public.load_out_lines to authenticated;

create function public.set_load_out_line(
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
    insert into public.load_out_lines as l (org_id, plant_id, load_date, route_id, item_type_id, qty)
    values (v_plant.org_id, v_plant.id, p_load_date, v_route.id, p_item_type_id, p_qty)
    on conflict (plant_id, load_date, route_id, item_type_id) where item_type_id is not null
    do update set qty = excluded.qty
    returning l.* into v_row;
  else
    insert into public.load_out_lines as l (org_id, plant_id, load_date, route_id, special_text, qty)
    values (v_plant.org_id, v_plant.id, p_load_date, v_route.id, v_text, p_qty)
    on conflict (plant_id, load_date, route_id, lower(special_text)) where special_text is not null
    do update set qty = excluded.qty, special_text = excluded.special_text
    returning l.* into v_row;
  end if;
  return v_row;
end;
$$;
comment on function public.set_load_out_line(uuid, date, uuid, int, uuid, text) is
  'Owner 2026-11-06 RPC (owner, or a manager granted can_enter_load_out; definer, permission first): sets one load-out line for p_load_date (plant-local; 7 days back to 30 ahead) and p_route_id (an active route that runs on that weekday): either p_item_type_id (active item; qty in its own count: packs for pack items, pieces for unit items) or p_special_text (1–80 chars) with p_qty (0–100,000; 0 = not needed). Upserts (same date + route + item/text). Returns the line. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.set_load_out_line(uuid, date, uuid, int, uuid, text) from public, anon;
grant execute on function public.set_load_out_line(uuid, date, uuid, int, uuid, text) to authenticated, service_role;

create function public.copy_load_out_from(p_plant_id uuid, p_from_date date, p_to_date date)
returns int language plpgsql volatile security definer set search_path = '' as $$
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
  insert into public.load_out_lines (org_id, plant_id, load_date, route_id, item_type_id, special_text, qty)
  select l.org_id, l.plant_id, p_to_date, l.route_id, l.item_type_id, l.special_text, l.qty
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
  'Owner 2026-11-06 RPC ("same as yesterday"; owner, or a manager granted can_enter_load_out): copies the lines with qty > 0 of p_from_date to p_to_date (7 days back to 30 ahead), only for active routes that run on p_to_date''s weekday and active items, never overwriting a line already set for p_to_date. Returns lines copied. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.copy_load_out_from(uuid, date, date) from public, anon;
grant execute on function public.copy_load_out_from(uuid, date, date) to authenticated, service_role;

-- ── Route loaded (append-only) ────────────────────────────────────────────
create table public.route_load_events (
  id          uuid primary key default gen_random_uuid(),
  seq         bigint generated always as identity,
  org_id      uuid not null,
  plant_id    uuid not null,
  route_id    uuid not null,
  load_date   date not null,
  loaded      boolean not null,
  occurred_at timestamptz not null default now(),
  entered_by  uuid references auth.users(id),
  client_id   uuid not null unique,
  created_at  timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (route_id, plant_id) references public.routes(id, plant_id)
);
alter table public.route_load_events enable row level security;
create index route_load_events_plant_org_idx on public.route_load_events (plant_id, org_id);
create index route_load_events_route_idx on public.route_load_events (route_id, plant_id, load_date, occurred_at desc, seq desc);
create index route_load_events_entered_by_idx on public.route_load_events (entered_by);
comment on table public.route_load_events is
  'Owner 2026-11-06: append-only "route loaded" / "not loaded" events per route and load date (latest wins). Written by mark_route_loaded (manager on duty or owner). A loaded event alerts the owners (route_loaded).';
create trigger route_load_events_prevent_mutation before update or delete on public.route_load_events
  for each row execute function app.prevent_mutation();
create trigger route_load_events_prevent_truncate before truncate on public.route_load_events
  for each statement execute function app.prevent_delete();
create trigger route_load_events_audit after insert on public.route_load_events for each row execute function app.audit();
create policy route_load_events_select on public.route_load_events for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')));
revoke all on public.route_load_events from anon, authenticated;
grant select (id, seq, org_id, plant_id, route_id, load_date, loaded, occurred_at, client_id, created_at)
  on public.route_load_events to authenticated;

create type public.route_load_result as (
  event_id   uuid,
  route_id   uuid,
  load_date  date,
  loaded     boolean,
  since      timestamptz,
  changed    boolean
);
comment on type public.route_load_result is 'mark_route_loaded result: the route''s state for that load date.';

create function public.mark_route_loaded(p_route_id uuid, p_load_date date, p_client_id uuid, p_loaded boolean default true)
returns public.route_load_result language plpgsql volatile security definer set search_path = '' as $$
declare
  v_r     record;
  v_e     public.route_load_events;
  v_today date;
begin
  -- Role check FIRST: a missing route and another tenant's route give the same answer.
  select r.id, r.org_id, r.plant_id, r.days_of_week, p.timezone into v_r
    from public.routes r join public.plants p on p.id = r.plant_id where r.id = p_route_id;
  if v_r.id is null or not app.has_role(v_r.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'mark_route_loaded requires the manager on duty or an owner';
  end if;
  if not app.has_role(v_r.plant_id, '{owner}')
     and not exists (select 1 from app.managers_on_duty(v_r.plant_id, pg_catalog.now()) u where u = (select auth.uid())) then
    raise exception 'NOT_AUTHORIZED' using detail = 'mark_route_loaded requires the manager on duty or an owner';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  select e.* into v_e from public.route_load_events e where e.client_id = p_client_id;
  if v_e.id is not null then
    if v_e.plant_id = v_r.plant_id then
      return (v_e.id, v_e.route_id, v_e.load_date, v_e.loaded, v_e.occurred_at, false)::public.route_load_result;
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  v_today := (pg_catalog.now() at time zone v_r.timezone)::date;
  if p_load_date is null or p_load_date < v_today - 1 or p_load_date > v_today + 1 then
    raise exception 'VALIDATION_FAILED' using detail = 'load_date: yesterday, today or tomorrow';
  end if;
  if not (extract(dow from p_load_date)::smallint = any (v_r.days_of_week)) then
    raise exception 'VALIDATION_FAILED' using detail = 'route_id: this route does not run on that weekday';
  end if;
  if p_loaded is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_loaded: true or false';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('route:' || v_r.id::text || p_load_date::text, 0));
  select e.* into v_e from public.route_load_events e
   where e.route_id = v_r.id and e.plant_id = v_r.plant_id and e.load_date = p_load_date
   order by e.occurred_at desc, e.seq desc limit 1;
  if coalesce(v_e.loaded, false) = p_loaded then
    return (v_e.id, v_r.id, p_load_date, p_loaded, v_e.occurred_at, false)::public.route_load_result;
  end if;
  insert into public.route_load_events as e (org_id, plant_id, route_id, load_date, loaded, entered_by, client_id)
  values (v_r.org_id, v_r.plant_id, v_r.id, p_load_date, p_loaded, (select auth.uid()), p_client_id)
  on conflict (client_id) do nothing
  returning e.* into v_e;
  if v_e.id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  if p_loaded then
    insert into public.alert_events (org_id, plant_id, kind, subject_id, recipients)
    values (v_r.org_id, v_r.plant_id, 'route_loaded', v_e.id, '{}');
  end if;
  return (v_e.id, v_e.route_id, v_e.load_date, v_e.loaded, v_e.occurred_at, true)::public.route_load_result;
end;
$$;
comment on function public.mark_route_loaded(uuid, date, uuid, boolean) is
  'Owner 2026-11-06 RPC (the manager on duty, per app.managers_on_duty, or an owner; definer, role check first): marks a route loaded (p_loaded true) or not loaded (false, to correct a mistake) for p_load_date (yesterday, today or tomorrow, plant-local; the route must run that weekday). Append-only route_load_events; a loaded event alerts the owners (alert_events route_loaded). Same state as now → nothing recorded (changed=false). Idempotent on p_client_id. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.mark_route_loaded(uuid, date, uuid, boolean) from public, anon;
grant execute on function public.mark_route_loaded(uuid, date, uuid, boolean) to authenticated, service_role;

-- ── The board ─────────────────────────────────────────────────────────────
create function public.get_load_out_board(p_plant_id uuid, p_load_date date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_p    record;
  v_date date;
  v_local timestamp;
begin
  select p.id, p.timezone into v_p from public.plants p where p.id = p_plant_id;
  if v_p.id is null or not app.has_role(v_p.id, '{owner,manager,lead,viewer}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_load_out_board requires a role on the plant';
  end if;
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
               'lines', coalesce((
                 select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                          'line_id', l.id, 'item_type_id', l.item_type_id, 'item_name', i.name, 'item_name_i18n', i.name_i18n,
                          'count_mode', i.count_mode, 'pack_size', i.pack_size, 'special_text', l.special_text, 'qty', l.qty)
                          order by (l.item_type_id is null), i.sort_order, i.name, l.special_text)
                   from public.load_out_lines l
                   left join public.item_types i on i.id = l.item_type_id and i.plant_id = l.plant_id
                  where l.plant_id = r.plant_id and l.route_id = r.id and l.load_date = v_date and l.qty > 0), '[]'::jsonb))
               order by r.load_time, r.sort_order, r.name)
        from public.routes r
        left join lateral (
          select e.loaded, e.occurred_at from public.route_load_events e
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
  'Owner 2026-11-06 read (owner/manager/lead/viewer; definer, role check first): the load-out for p_load_date (default: the next loading morning, plant-local: today before noon, else tomorrow). jsonb {plant_id, load_date, routes[{route_id, name, load_time, loaded, loaded_since, lines[{line_id, item_type_id, item_name, item_name_i18n, count_mode, pack_size, special_text, qty}]}] (only active routes that run on that weekday, by load time), totals[{item_type_id, item_name, item_name_i18n, count_mode, pack_size, qty}] (items only; specials stay per route), server_time}. qty is in the item''s own count (packs for pack items). Never says who typed or loaded. Errors: NOT_AUTHORIZED.';
revoke all on function public.get_load_out_board(uuid, date) from public, anon;
grant execute on function public.get_load_out_board(uuid, date) to authenticated, service_role;

-- ── Push: route_loaded → the owners ───────────────────────────────────────
CREATE OR REPLACE FUNCTION app.alert_recipient_users(p_alert alert_events)
 RETURNS SETOF uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_alert.kind = 'machine_down' then
    return query
      select distinct m.user_id from public.memberships m
        join public.plants p on p.id = p_alert.plant_id and p.org_id = m.org_id
       where m.revoked_at is null and m.role in ('owner', 'manager') and m.notify_machine_down
         and (m.plant_id is null or m.plant_id = p_alert.plant_id);
  elsif p_alert.kind = 'washer_idle' then
    return query
      select u from app.plant_owner_users(p_alert.plant_id) u
      union
      select u from app.managers_on_duty(p_alert.plant_id, p_alert.sent_at) u;
  elsif p_alert.kind = 'route_loaded' then
    return query select u from app.plant_owner_users(p_alert.plant_id) u;
  end if;
  -- Other kinds are added by their own migrations.
end;
$function$;

CREATE OR REPLACE FUNCTION app.alert_payload(p_alert alert_events)
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
             'idle_since', c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes),
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
  end if;
  return coalesce(v, '{}'::jsonb);
end;
$function$;
