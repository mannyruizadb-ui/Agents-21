-- Day reports, history and pace are owner-only (owner 2026-11-04, round 2: "pace screen: deferred,
-- and owner-only when built"; day reports / history owner-only). get_day_report and
-- get_wash_group_pace now require the OWNER role on the plant (was owner/manager/lead/viewer); the
-- bodies are unchanged. get_shift_report stays open to owner/manager/lead/viewer (the shift report
-- each area gets).
--
-- Not changed here (a role/RLS change the owner must confirm screen by screen first, CLAUDE.md
-- 2026-11-04 round 1): the reporting VIEWS (daily_reconciliation, washroom_by_shift, finished_by_shift,
-- current_soil_estimates) are security_invoker and still readable by every role of the plant.

CREATE OR REPLACE FUNCTION public.get_day_report(p_plant_id uuid, p_production_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_p         record;
  v_day_start timestamptz;
  v_day_end   timestamptz;
begin
  select p.id, p.timezone, p.production_day_start into v_p from public.plants p where p.id = p_plant_id;
  if v_p.id is null or not app.has_role(v_p.id, '{owner}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_day_report requires owner on the plant';
  end if;
  if p_production_date is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_production_date: required';
  end if;
  -- Same bounds as daily_reconciliation: first instance start → last instance end of the day, else
  -- the production-day bounds (production_day_start local → next day's).
  select coalesce(min(si.starts_at), (p_production_date + v_p.production_day_start) at time zone v_p.timezone),
         coalesce(max(si.ends_at), ((p_production_date + 1) + v_p.production_day_start) at time zone v_p.timezone)
    into v_day_start, v_day_end
    from public.shift_instances si
   where si.plant_id = v_p.id and si.production_date = p_production_date and si.skipped_at is null;

  return jsonb_build_object(
    'plant_id', v_p.id,
    'production_date', p_production_date,
    'day_start', v_day_start,
    'day_end', v_day_end,
    'shifts', coalesce((
      select jsonb_agg(jsonb_build_object('id', si.id, 'area_id', si.area_id, 'area_name', a.name, 'area_kind', a.kind,
                                          'name', s.name, 'starts_at', si.starts_at, 'ends_at', si.ends_at)
             order by a.sort_order, si.starts_at)
        from public.shift_instances si
        join public.shifts s on s.id = si.shift_id
        join public.areas a on a.id = si.area_id
       where si.plant_id = v_p.id and si.production_date = p_production_date and si.skipped_at is null), '[]'::jsonb),
    'reconciliation', coalesce((
      select jsonb_agg(jsonb_build_object(
               'wash_group_id', d.wash_group_id, 'wash_group_name', d.wash_group_name,
               'wash_group_name_i18n', d.wash_group_name_i18n, 'ships_next_morning', g.ships_next_morning,
               'est_loads_start', d.est_loads_start, 'est_loads_end', d.est_loads_end,
               'loads_run', d.loads_run, 'standard_loads', d.standard_loads, 'rewash_loads', d.rewash_loads,
               'pieces_finished', d.pieces_finished, 'items_finished', d.items_finished,
               'pieces_without_conversion', d.pieces_without_conversion, 'finished_incomplete', d.finished_incomplete,
               'loads_finished_approx', d.loads_finished_approx,
               'loads_finished_partial_approx', d.loads_finished_partial_approx,
               'clean_backlog_loads_approx', d.clean_backlog_loads_approx, 'approximate', d.approximate)
             order by g.sort_order, g.name)
        from public.daily_reconciliation d
        join public.wash_groups g on g.id = d.wash_group_id
       where d.plant_id = v_p.id and d.production_date = p_production_date), '[]'::jsonb),
    -- Soil for EVERY wash group with an estimate by the day's end (also groups with no activity).
    'soil', coalesce((
      select jsonb_agg(jsonb_build_object('wash_group_id', g.id, 'wash_group_name', g.name, 'wash_group_name_i18n', g.name_i18n,
                                          'est_loads_start', es.qty_loads, 'est_loads_end', ee.qty_loads,
                                          'has_conversion', ee.qty_loads is not null)
             order by g.sort_order, g.name)
        from public.wash_groups g
        left join lateral (
          select app.to_loads(e.wash_group_id, null, e.qty, e.unit) as qty_loads from public.soil_estimates e
           where e.plant_id = g.plant_id and e.wash_group_id = g.id and e.entered_at <= v_day_start
           order by e.entered_at desc, e.id desc limit 1) es on true
        cross join lateral (
          select app.to_loads(e.wash_group_id, null, e.qty, e.unit) as qty_loads, e.id from public.soil_estimates e
           where e.plant_id = g.plant_id and e.wash_group_id = g.id and e.entered_at <= v_day_end
           order by e.entered_at desc, e.id desc limit 1) ee
       where g.plant_id = v_p.id), '[]'::jsonb),
    'totals', jsonb_build_object(
      'loads_run',       coalesce((select sum(d.loads_run) from public.daily_reconciliation d where d.plant_id = v_p.id and d.production_date = p_production_date), 0),
      'standard_loads',  coalesce((select sum(d.standard_loads) from public.daily_reconciliation d where d.plant_id = v_p.id and d.production_date = p_production_date), 0),
      'rewash_loads',    coalesce((select sum(d.rewash_loads) from public.daily_reconciliation d where d.plant_id = v_p.id and d.production_date = p_production_date), 0),
      'pieces_finished', coalesce((select sum(d.pieces_finished) from public.daily_reconciliation d where d.plant_id = v_p.id and d.production_date = p_production_date), 0)),
    -- Work outside any shift instance (e.g. the noon helper): counted in the day, shown separately.
    'off_shift', jsonb_build_object(
      'loads_run',      coalesce((select sum(w.loads_run) from public.washroom_by_shift w
                                   where w.plant_id = v_p.id and w.shift_instance_id is null and w.production_date = p_production_date), 0),
      'standard_loads', coalesce((select sum(w.standard_loads) from public.washroom_by_shift w
                                   where w.plant_id = v_p.id and w.shift_instance_id is null and w.production_date = p_production_date), 0),
      'pieces',         coalesce((select sum(f.pieces) from public.finished_by_shift f
                                   where f.plant_id = v_p.id and f.shift_instance_id is null and f.production_date = p_production_date), 0)),
    'server_time', pg_catalog.now());
end;
$function$

;
comment on function public.get_day_report(uuid, date) is
  'G1 day report (OWNER only, owner 2026-11-04; definer, role check first, plant-filtered) for one PRODUCTION DAY (plants.production_day_start, default 12:00 → 12:00). jsonb: {plant_id, production_date, day_start, day_end, shifts[{id, area_id, area_name, area_kind, name, starts_at, ends_at}], reconciliation[{wash_group_id, wash_group_name, wash_group_name_i18n, ships_next_morning, est_loads_start, est_loads_end, loads_run, standard_loads, rewash_loads, pieces_finished, items_finished, pieces_without_conversion, finished_incomplete, loads_finished_approx, loads_finished_partial_approx, clean_backlog_loads_approx, approximate}], soil[{wash_group_id, wash_group_name, wash_group_name_i18n, est_loads_start, est_loads_end, has_conversion}], totals{loads_run, standard_loads, rewash_loads, pieces_finished}, off_shift{loads_run, standard_loads, pieces}, server_time}. Rows come from daily_reconciliation (voided rows excluded). No per-person data. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';

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
    left join lateral (
      select coalesce(sum(c.load_count * c.load_factor_used), 0)::numeric as loads
        from public.washer_cycles c
       where e.id is not null and c.plant_id = g.plant_id and c.wash_group_id = g.id
         and c.voided_at is null and not c.is_rewash and c.started_at > e.entered_at) s on true
   where g.plant_id = v_p.id and (g.active or t.wash_group_id is not null)
   order by g.ships_next_morning desc, g.sort_order, g.name;
end;
$function$

;
comment on function public.get_wash_group_pace(uuid, date) is
  'G6 owner pace cards, actuals only (OWNER only, owner 2026-11-04; definer, role check first, plant-filtered). One row per active wash group (plus inactive groups with loads that day), next-morning groups first: loads_run / standard_loads / rewash_loads for the production day (default: the current one), last_load_at, the latest soil estimate (qty, unit, estimate_loads via app.to_loads, age, freshness), standard_loads_since_estimate and backlog_loads_approx (≈, never below 0; null without a conversion), open queue items / remaining loads. Goals and alerts are later (G6: about 2 weeks after go-live). No per-person data. Errors: NOT_AUTHORIZED.';
