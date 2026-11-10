-- Owner 2026-11-10, one "loads left" rule for every screen: loads left = the group's current estimate
-- (whole loads, ceil(round(loads, 2)), the app's wholeLoads rounding) minus the starts of that group since
-- the estimate was entered, EACH START = 1 LOAD (not load_factor), on-queue or off-queue. The counter is
-- app.estimate_starts_since (20261110104601: live = not voided, not rewash, started_at > entered_at).
--
-- 1. current_soil_estimates + loads_left integer (last column; security_invoker kept, existing columns and
--    order kept, grants unchanged): greatest(0, ceil(round(L, 2)) − starts since entered_at), L = qty for
--    unit 'load', else qty_loads; null when there is no factor (qty_loads null). The counter is a definer
--    helper because washer_cycles RLS shows managers / leads / viewers only the current shift's cycles and
--    displays none; it returns only a count, to the same readers as soil_estimates. The distinct-on is now
--    a subquery so the counter runs once per group, not once per historical estimate.
-- 2. get_wash_group_pace: standard_loads_since_estimate (name and type kept) is now the number of those
--    starts (each start = 1 load; was Σ load_count × load_factor_used); backlog_loads_approx follows it.
--    Everything else unchanged.
-- The open from_estimate queue item agrees at sync time: its loads_remaining = loads_left (see
-- app.sync_estimate_queue_item).

create or replace view public.current_soil_estimates with (security_invoker = true) as
select c.org_id, c.plant_id, c.wash_group_id, c.wash_group_name, c.wash_group_name_i18n, c.estimate_id, c.qty, c.unit,
       c.qty_loads, c.has_conversion, c.entered_at, c.age_minutes, c.freshness,
       case when (case when c.unit = 'load' then c.qty else c.qty_loads end) is not null
            then greatest(0, pg_catalog.ceil(pg_catalog.round(case when c.unit = 'load' then c.qty else c.qty_loads end, 2))::int
                             - app.estimate_starts_since(c.plant_id, c.wash_group_id, c.entered_at)) end as loads_left
  from (select distinct on (e.plant_id, e.wash_group_id)
               e.org_id, e.plant_id, e.wash_group_id, g.name as wash_group_name, g.name_i18n as wash_group_name_i18n,
               e.id as estimate_id, e.qty, e.unit,
               app.to_loads(e.wash_group_id, null, e.qty, e.unit) as qty_loads,
               app.to_loads(e.wash_group_id, null, e.qty, e.unit) is not null as has_conversion,
               e.entered_at,
               floor(extract(epoch from now() - e.entered_at) / 60::numeric)::integer as age_minutes,
               case when (now() - e.entered_at) >= make_interval(mins => p.estimate_red_minutes) then 'red'::text
                    when (now() - e.entered_at) >= make_interval(mins => p.estimate_amber_minutes) then 'amber'::text
                    else 'ok'::text end as freshness
          from public.soil_estimates e
          join public.plants p on p.id = e.plant_id
          join public.wash_groups g on g.id = e.wash_group_id
         order by e.plant_id, e.wash_group_id, e.entered_at desc, e.id desc) c;
comment on view public.current_soil_estimates is
  '§4.6 Latest soil estimate per wash group (by entered_at) with load equivalent via app.to_loads (basket / bin via the group''s loads_per_basket / loads_per_bin; null = no conversion), age and freshness (ok/amber/red per plant thresholds), and loads_left (owner 2026-11-10, the one "loads left" rule for every dirty-work number: greatest(0, ceil(round(estimate loads, 2)) − live non-rewash starts of the group since entered_at, each start = 1 load, any queue item or off-queue); null without a conversion). No entered_by / staff / names (owner 2026-11-04).';

CREATE OR REPLACE FUNCTION public.get_wash_group_pace(p_plant_id uuid, p_production_date date DEFAULT NULL::date)
 RETURNS TABLE(production_date date, wash_group_id uuid, wash_group_name text, wash_group_name_i18n jsonb, color_hex text, sort_order integer, ships_next_morning boolean, loads_run integer, standard_loads numeric, rewash_loads integer, last_load_at timestamp with time zone, estimate_qty numeric, estimate_unit app.qty_unit, estimate_loads numeric, estimate_entered_at timestamp with time zone, estimate_age_minutes integer, estimate_freshness text, standard_loads_since_estimate numeric, backlog_loads_approx numeric, queue_open_items integer, queue_loads_remaining integer, queue_items_without_load_count integer, server_time timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
         v_now
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
$function$;

comment on function public.get_wash_group_pace(uuid, date) is
  'G6 owner pace cards, actuals only (OWNER only, owner 2026-11-04; definer, role check first, plant-filtered). One row per active wash group (plus inactive groups with loads that day), next-morning groups first: loads_run / standard_loads / rewash_loads for the production day (default: the current one), last_load_at, the latest soil estimate (qty, unit, estimate_loads via app.to_loads, age, freshness), standard_loads_since_estimate (owner 2026-11-10: the NUMBER of live non-rewash starts of the group since the estimate was entered, each start = 1 load, app.estimate_starts_since; was Σ load_count × load_factor) and backlog_loads_approx (estimate loads − that, ≈, never below 0; null without a conversion), open queue items / remaining loads. Goals and alerts are later (G6: about 2 weeks after go-live). No per-person data. Errors: NOT_AUTHORIZED.';
