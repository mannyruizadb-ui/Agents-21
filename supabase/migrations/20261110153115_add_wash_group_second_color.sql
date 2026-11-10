-- Two-colour swatches for mixed wash groups (owner 2026-11-10): a group that washes two fabric colours
-- together (Napkins – Green & Red, Red & blue tablecloths, …) shows both on the boards and pickers.
--
-- 1. wash_groups.color_hex_2 text null: the second colour (null = single colour). Same format CHECK as
--    color_hex (^#[0-9A-Fa-f]{6}$). OWNER-ONLY edit like the rest of wash_groups (owner-only INSERT/UPDATE
--    policies since 20261109215626; this adds the column UPDATE grant; INSERT/SELECT are table-level grants).
-- 2. Screens get it next to the first colour (columns APPENDED, existing order unchanged):
--    * view public.queue_board          + wash_group_color_hex_2
--    * public.get_queue(uuid)           + wash_group_color_hex_2
--    * public.get_washroom_board(uuid)  + wash_group_color_hex_2, next_wash_group_color_hex_2
--    * public.get_wash_group_pace(uuid, date) + color_hex_2 (its first colour column is named color_hex)
--    A function's OUT columns cannot change in place, so the three functions are dropped and re-created with
--    the same body, comment and grants (revoked from public/anon, execute to authenticated). Nothing depends
--    on them in the database. Direct reads of wash_groups get the column as is.
-- 3. DATA through app.apply_wash_group_colors(plant) (seed.sql calls the same function on a fresh database):
--    ours (no customer): Napkins – Green & Red #15803D / #DC2626 · Red & blue tablecloths #DC2626 / #1D4ED8 ·
--    Napkins – Bone & Chambray #E7DCC4 / #8FA9C8 · Napkins – Navy Blue w/ Stripe #1E3A8A (single) ·
--    Napkins – Pink #EC4899 (single); AA Linen's Colored napkins and Colored tablecloths #DC2626 / #1D4ED8.
--    Matching by name within the plant (case, extra spaces, – or - ignored). Idempotent. The NOTICE carries
--    counts only (it lands in the public deploy log).

-- ── 1. Column ─────────────────────────────────────────────────────────────
alter table public.wash_groups
  add column color_hex_2 text null,
  add constraint wash_groups_color_hex_2_check check (color_hex_2 ~ '^#[0-9A-Fa-f]{6}$');
comment on column public.wash_groups.color_hex_2 is
  'Owner 2026-11-10: second swatch colour for a group that washes two fabric colours together (e.g. Napkins – Green & Red). Null = single colour (color_hex only). Same format as color_hex. Owner-only edit (wash_groups RLS).';
grant update (color_hex_2) on public.wash_groups to authenticated;

-- ── 2a. queue_board (+ wash_group_color_hex_2 at the end) ─────────────────
create or replace view public.queue_board with (security_invoker = true) as
select q.org_id,
       q.plant_id,
       q.area_id,
       q.id,
       q."position",
       q.is_rush,
       q.status,
       q.qty,
       q.unit,
       app.to_loads(q.wash_group_id, q.item_type_id, q.qty, q.unit) as qty_loads,
       q.unit = any (array['piece'::app.qty_unit, 'pack'::app.qty_unit]) as approximate,
       q.wash_group_id,
       g.name as wash_group_name,
       g.name_i18n as wash_group_name_i18n,
       g.color_hex as wash_group_color_hex,
       q.item_type_id,
       i.name as item_name,
       i.name_i18n as item_name_i18n,
       i.color_hex as item_color_hex,
       q.note,
       q.version,
       q.started_at,
       q.created_at,
       q.assigned_machine_id,
       m.name as assigned_machine_name,
       q.is_rewash,
       q.loads_started,
       n.loads_needed,
       case when n.loads_needed is not null then greatest(n.loads_needed - q.loads_started, 0) end as loads_remaining,
       g.color_hex_2 as wash_group_color_hex_2
  from public.queue_items q
  join public.wash_groups g on g.id = q.wash_group_id
  left join public.item_types i on i.id = q.item_type_id
  left join public.machines m on m.id = q.assigned_machine_id
  cross join lateral (select app.queue_loads_needed(q.wash_group_id, q.item_type_id, q.qty, q.unit) as loads_needed) n
 where q.status = any (array['queued'::app.queue_status, 'in_progress'::app.queue_status]);
comment on view public.queue_board is
  '§4.6 Open queue (queued/in_progress) per area: wash group names in all languages, plus the optional item; qty_loads via app.to_loads (piece/pack approximate, null without a factor); assigned_machine_id/name (null = next free washer); is_rewash; loads_started / loads_needed / loads_remaining (M2 start-taps; loads_needed null = unknown, completed by hand; loads_remaining null whenever loads_needed is null, since 2026-11-09); wash_group_color_hex_2 (owner 2026-11-10: second swatch colour of a two-colour group, null = single). Order by is_rush desc, position asc.';

-- ── 2b. get_queue (+ wash_group_color_hex_2 at the end) ───────────────────
drop function public.get_queue(uuid);
create function public.get_queue(p_area_id uuid)
returns table (org_id uuid, plant_id uuid, area_id uuid, id uuid, "position" numeric, is_rush boolean,
               status app.queue_status, qty numeric, unit app.qty_unit, qty_loads numeric, approximate boolean,
               wash_group_id uuid, wash_group_name text, wash_group_name_i18n jsonb, wash_group_color_hex text,
               item_type_id uuid, item_name text, item_name_i18n jsonb, item_color_hex text, note text,
               version integer, started_at timestamptz, created_at timestamptz, assigned_machine_id uuid,
               assigned_machine_name text, is_rewash boolean, loads_started integer, loads_needed integer,
               loads_remaining integer, created_by_name text, from_estimate boolean, wash_group_color_hex_2 text)
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
         q.from_estimate,
         b.wash_group_color_hex_2
    from public.queue_board b
    join public.queue_items q on q.id = b.id and q.plant_id = b.plant_id
   where b.area_id = v_area.id and b.plant_id = v_area.plant_id
   order by b.is_rush desc, b."position", b.id;
end;
$$;
comment on function public.get_queue(uuid) is
  'C1–C4 read (owner/manager/lead/viewer on the plant, or a display of this area; definer, role check first): the area''s open queue in board order (rush first, then position). Columns = queue_board (incl. loads_started / loads_needed / loads_remaining) + created_by_name (owner 2026-11-06: who added the item; OWNER callers only, null for every other role) + from_estimate (owner 2026-11-09: the item is kept in step with the group''s dirty-work estimate) + wash_group_color_hex_2 (owner 2026-11-10: second swatch colour, null = single). Errors: NOT_AUTHORIZED.';
revoke all on function public.get_queue(uuid) from public, anon, authenticated;
grant execute on function public.get_queue(uuid) to authenticated, service_role;

-- ── 2c. get_washroom_board (+ wash_group_color_hex_2, next_wash_group_color_hex_2) ──
drop function public.get_washroom_board(uuid);
create function public.get_washroom_board(p_area_id uuid)
returns table (machine_id uuid, machine_name text, load_factor numeric, status text, cycle_id uuid,
               wash_group_id uuid, wash_group_name text, wash_group_name_i18n jsonb, wash_group_color_hex text,
               is_rewash boolean, wash_formula_id uuid, formula_external_no text, formula_name text,
               cycle_minutes integer, started_at timestamptz, expected_end_at timestamptz,
               minutes_since_start integer, minutes_ready integer, queue_item_id uuid, next_queue_item_id uuid,
               next_is_assigned boolean, next_wash_group_id uuid, next_wash_group_name text,
               next_wash_group_name_i18n jsonb, next_wash_group_color_hex text, next_item_type_id uuid,
               next_item_name text, next_item_name_i18n jsonb, next_qty numeric, next_unit app.qty_unit,
               next_is_rush boolean, next_is_rewash boolean, next_loads_remaining integer, next_version integer,
               server_time timestamptz, is_down boolean, down_reason text, down_since timestamptz,
               down_reason_code text, down_reason_label_i18n jsonb,
               wash_group_color_hex_2 text, next_wash_group_color_hex_2 text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_area   record;
  v_now    timestamptz := pg_catalog.now();
  v_reason boolean;
begin
  select a.id, a.plant_id into v_area from public.areas a where a.id = p_area_id;
  if v_area.id is null
     or not (app.has_role(v_area.plant_id, '{owner,manager,lead,viewer}')
             or (app.is_display(v_area.plant_id) and (app.my_device()).area_id = v_area.id)) then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_washroom_board requires a role on the area''s plant, or a display of this area';
  end if;
  v_reason := app.has_role(v_area.plant_id, '{owner,manager}');   -- L6: free-text reasons for owner/manager only

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
         case when app.queue_loads_needed(n.wash_group_id, n.item_type_id, n.qty, n.unit) is not null
              then greatest(app.queue_loads_needed(n.wash_group_id, n.item_type_id, n.qty, n.unit) - n.loads_started, 0) end,
         n.version,
         v_now,
         coalesce(s.status = 'down', false),
         case when s.status = 'down' and v_reason then s.reason end,
         case when s.status = 'down' then s.occurred_at end,
         case when s.status = 'down' and v_reason then s.reason_code end,
         case when s.status = 'down' and v_reason then s.label_i18n end,
         g.color_hex_2,
         ng.color_hex_2
    from public.machines m
    left join lateral (
      select e.status, e.reason, e.reason_code, e.occurred_at, r.label_i18n from public.machine_status_events e
        left join public.machine_down_reasons r on r.plant_id = e.plant_id and r.code = e.reason_code
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
  'D1/G6 read (owner/manager/lead/viewer, or a display of this area): one row per ACTIVE washer of the area, in name order: the current (latest live) cycle with group, formula, started_at, expected_end_at = started_at + cycle_minutes, status idle|running|ready|unknown (no cycle time), minutes_ready; and NEXT = the top open item assigned to this washer, else the top open unassigned item (the same unassigned item can be NEXT on several washers: "next free washer"). is_down / down_reason / down_since (owner 2026-11-04; down_reason only for owner/manager, null for lead, viewer and display: security review L6): a down washer takes precedence over status, shows no NEXT, and refuses start-taps. server_time for data age. No per-person data. down_reason_code (owner 2026-11-04): the preset reason (water_pump | soap_dispenser | wont_start | leaking | other), translated by the client; same per-role hiding as down_reason. down_reason_label_i18n (owner 2026-11-05): the reason''s label in every language, same hiding as down_reason_code. wash_group_color_hex_2 / next_wash_group_color_hex_2 (owner 2026-11-10): second swatch colour of the current / NEXT group, null = single colour.';
revoke all on function public.get_washroom_board(uuid) from public, anon, authenticated;
grant execute on function public.get_washroom_board(uuid) to authenticated, service_role;

-- ── 2d. get_wash_group_pace (+ color_hex_2 at the end) ────────────────────
drop function public.get_wash_group_pace(uuid, date);
create function public.get_wash_group_pace(p_plant_id uuid, p_production_date date default null)
returns table (production_date date, wash_group_id uuid, wash_group_name text, wash_group_name_i18n jsonb,
               color_hex text, sort_order integer, ships_next_morning boolean, loads_run integer,
               standard_loads numeric, rewash_loads integer, last_load_at timestamptz, estimate_qty numeric,
               estimate_unit app.qty_unit, estimate_loads numeric, estimate_entered_at timestamptz,
               estimate_age_minutes integer, estimate_freshness text, standard_loads_since_estimate numeric,
               backlog_loads_approx numeric, queue_open_items integer, queue_loads_remaining integer,
               queue_items_without_load_count integer, server_time timestamptz, color_hex_2 text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_p    record;
  v_day  date;
  v_now  timestamptz := pg_catalog.now();
begin
  select p.id, p.timezone, p.production_day_start, p.estimate_amber_minutes, p.estimate_red_minutes
    into v_p from public.plants p where p.id = p_plant_id;
  if v_p.id is null or not app.has_role(v_p.id, '{owner}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_wash_group_pace requires owner on the plant';
  end if;
  v_day := coalesce(p_production_date, app.production_date(v_now, v_p.timezone, v_p.production_day_start));

  return query
  with today as (
    select w.wash_group_id, sum(w.loads_run)::int as loads_run, sum(w.standard_loads) as standard_loads,
           sum(w.rewash_loads)::int as rewash_loads
      from public.washroom_by_shift w
     where w.plant_id = v_p.id and w.production_date = v_day and w.wash_group_id is not null
     group by w.wash_group_id
  ), last_load as (
    select c.wash_group_id, max(c.started_at) as last_load_at
      from public.washer_cycles c
     where c.plant_id = v_p.id and c.voided_at is null
       and coalesce(c.production_date, app.production_date(c.started_at, v_p.timezone, v_p.production_day_start)) = v_day
     group by c.wash_group_id
  ), queue as (
    select b.wash_group_id, count(*)::int as open_items,
           coalesce(sum(b.loads_remaining), 0)::int as loads_remaining,
           count(*) filter (where b.loads_needed is null)::int as without_count
      from public.queue_board b
     where b.plant_id = v_p.id
     group by b.wash_group_id
  )
  select v_day, g.id, g.name, g.name_i18n, g.color_hex, g.sort_order, g.ships_next_morning,
         coalesce(t.loads_run, 0), coalesce(t.standard_loads, 0), coalesce(t.rewash_loads, 0), ll.last_load_at,
         e.qty, e.unit, e.qty_loads, e.entered_at,
         (extract(epoch from (v_now - e.entered_at)) / 60)::int,
         case when e.id is null then null
              when v_now - e.entered_at >= pg_catalog.make_interval(mins => v_p.estimate_red_minutes) then 'red'
              when v_now - e.entered_at >= pg_catalog.make_interval(mins => v_p.estimate_amber_minutes) then 'amber'
              else 'ok' end,
         s.loads,
         case when e.qty_loads is not null then greatest(e.qty_loads - coalesce(s.loads, 0), 0) end,
         coalesce(q.open_items, 0), coalesce(q.loads_remaining, 0), coalesce(q.without_count, 0),
         v_now,
         g.color_hex_2
    from public.wash_groups g
    left join today t on t.wash_group_id = g.id
    left join last_load ll on ll.wash_group_id = g.id
    left join queue q on q.wash_group_id = g.id
    left join lateral (
      select se.id, se.qty, se.unit, se.entered_at, app.to_loads(se.wash_group_id, null, se.qty, se.unit) as qty_loads
        from public.soil_estimates se
       where se.plant_id = g.plant_id and se.wash_group_id = g.id
       order by se.entered_at desc, se.id desc limit 1) e on true
    -- Owner 2026-11-10: each live start since the estimate = 1 load (app.estimate_starts_since).
    left join lateral (
      select coalesce(case when e.id is not null then app.estimate_starts_since(g.plant_id, g.id, e.entered_at) end, 0)::numeric as loads) s on true
   where g.plant_id = v_p.id and (g.active or t.wash_group_id is not null)
   order by g.ships_next_morning desc, g.sort_order, g.name;
end;
$$;
comment on function public.get_wash_group_pace(uuid, date) is
  'G6 owner pace cards, actuals only (OWNER only, owner 2026-11-04; definer, role check first, plant-filtered). One row per active wash group (plus inactive groups with loads that day), next-morning groups first: loads_run / standard_loads / rewash_loads for the production day (default: the current one), last_load_at, the latest soil estimate (qty, unit, estimate_loads via app.to_loads, age, freshness), standard_loads_since_estimate (owner 2026-11-10: the NUMBER of live non-rewash starts of the group since the estimate was entered, each start = 1 load, app.estimate_starts_since; was Σ load_count × load_factor) and backlog_loads_approx (estimate loads − that, ≈, never below 0; null without a conversion), open queue items / remaining loads; color_hex_2 (owner 2026-11-10: second swatch colour, null = single). Goals and alerts are later (G6: about 2 weeks after go-live). No per-person data. Errors: NOT_AUTHORIZED.';
revoke all on function public.get_wash_group_pace(uuid, date) from public, anon, authenticated;
grant execute on function public.get_wash_group_pace(uuid, date) to authenticated, service_role;

-- ── 3. DATA: two-colour groups and the single-colour napkin fixes ─────────
create function app.apply_wash_group_colors(p_plant_id uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_set     int := 0;
  v_missing int := 0;
  v_result  jsonb;
  -- customer null = ours; names compared lower-case, single spaces, en dash.
  v_targets constant jsonb := '[
    {"customer": null,       "name": "napkins – green & red",         "c1": "#15803D", "c2": "#DC2626"},
    {"customer": null,       "name": "red & blue tablecloths",        "c1": "#DC2626", "c2": "#1D4ED8"},
    {"customer": null,       "name": "napkins – bone & chambray",     "c1": "#E7DCC4", "c2": "#8FA9C8"},
    {"customer": null,       "name": "napkins – navy blue w/ stripe", "c1": "#1E3A8A", "c2": null},
    {"customer": null,       "name": "napkins – pink",                "c1": "#EC4899", "c2": null},
    {"customer": "aa linen", "name": "colored napkins",               "c1": "#DC2626", "c2": "#1D4ED8"},
    {"customer": "aa linen", "name": "colored tablecloths",           "c1": "#DC2626", "c2": "#1D4ED8"}]';
begin
  if p_plant_id is null or not exists (select 1 from public.plants p where p.id = p_plant_id) then
    raise exception 'VALIDATION_FAILED' using detail = 'apply_wash_group_colors: unknown plant';
  end if;

  with groups as (
    select g.id,
           replace(lower(regexp_replace(btrim(g.name), '\s+', ' ', 'g')), ' - ', ' – ') as n,
           lower(regexp_replace(btrim(c.name), '\s+', ' ', 'g')) as cust
      from public.wash_groups g
      left join public.customers c on c.id = g.customer_id and c.plant_id = g.plant_id
     where g.plant_id = p_plant_id
  )
  update public.wash_groups w
     set color_hex = t.c1, color_hex_2 = t.c2
    from groups x
    join pg_catalog.jsonb_to_recordset(v_targets) as t(customer text, name text, c1 text, c2 text) on t.name = x.n and t.customer is not distinct from x.cust
   where w.id = x.id
     and (upper(w.color_hex), upper(w.color_hex_2)) is distinct from (t.c1, t.c2);
  get diagnostics v_set = row_count;

  select count(*) into v_missing
    from pg_catalog.jsonb_to_recordset(v_targets) as t(customer text, name text, c1 text, c2 text)
   where not exists (
     select 1 from public.wash_groups g
       left join public.customers c on c.id = g.customer_id and c.plant_id = g.plant_id
      where g.plant_id = p_plant_id
        and replace(lower(regexp_replace(btrim(g.name), '\s+', ' ', 'g')), ' - ', ' – ') = t.name
        and lower(regexp_replace(btrim(c.name), '\s+', ' ', 'g')) is not distinct from t.customer);

  v_result := jsonb_build_object('groups', v_set, 'targets_not_found', v_missing);
  -- Counts only (the NOTICE lands in the public deploy log; never names).
  raise notice 'apply_wash_group_colors: % groups recoloured; % of 7 targets not found', v_set, v_missing;
  return v_result;
end;
$$;
comment on function app.apply_wash_group_colors(uuid) is
  'Owner 2026-11-10, one-shot data change for one plant, shared by migration 20261110153115 (cloud, ADB plant) and seed.sql: sets (color_hex, color_hex_2) on our Napkins – Green & Red (#15803D, #DC2626), Red & blue tablecloths (#DC2626, #1D4ED8), Napkins – Bone & Chambray (#E7DCC4, #8FA9C8), Napkins – Navy Blue w/ Stripe (#1E3A8A, null), Napkins – Pink (#EC4899, null) and AA Linen''s Colored napkins / Colored tablecloths (#DC2626, #1D4ED8). Name match within the plant (case, spaces, – / - ignored; customer by name, ours = no customer). Idempotent (skips rows already set). Returns {groups, targets_not_found}; the NOTICE carries counts only. VALIDATION_FAILED on an unknown plant. Postgres only.';
revoke all on function app.apply_wash_group_colors(uuid) from public, anon, authenticated;

-- The ADB plant (no row on a fresh database: seed.sql calls the function itself).
select app.apply_wash_group_colors(p.id)
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami';
