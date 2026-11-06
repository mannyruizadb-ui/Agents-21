-- M2 launch reports (owner 2026-11-03: "reports must be live at launch"; PRD G1, G6; §5.3).
-- One call each for the UI:
--   get_shift_report(p_shift_instance_id)          one area's shift (washroom loads per wash group, or
--                                                  finished goods per item with lines), queue
--   get_day_report(p_plant_id, p_production_date)  the production day: washed vs finished per wash group
--                                                  (daily_reconciliation), soil start/end, shifts, off-shift
--   get_wash_group_pace(p_plant_id, p_production_date default today)
--                                                  the owner's pace cards: loads today per wash group,
--                                                  backlog from the latest estimate, next-morning flag
-- All three are SECURITY DEFINER (the 001 schema guard: every public RPC is definer) over the existing
-- report views. They check owner/manager/lead/viewer on the plant FIRST (a display, another tenant or a
-- missing id → the same NOT_AUTHORIZED), and every query is then filtered by that plant (or by the
-- shift instance / its area), because RLS does not apply inside a definer function. Totals per wash group / item / line / shift / day only: never per person
-- (§6.2 #11); no staff or entered_by column is read.

-- ── get_shift_report (G1 shift report) ────────────────────────────────────
create function public.get_shift_report(p_shift_instance_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_si record;
begin
  select si.id, si.plant_id, si.area_id, si.shift_id, si.business_date, si.production_date, si.starts_at, si.ends_at,
         si.skipped_at, s.name, a.name as area_name, a.kind as area_kind
    into v_si
    from public.shift_instances si
    join public.shifts s on s.id = si.shift_id
    join public.areas a on a.id = si.area_id
   where si.id = p_shift_instance_id;
  if v_si.id is null or not app.has_role(v_si.plant_id, '{owner,manager,lead,viewer}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_shift_report requires owner, manager, lead or viewer on the shift''s plant';
  end if;

  return jsonb_build_object(
    'shift', jsonb_build_object(
      'id', v_si.id, 'area_id', v_si.area_id, 'area_name', v_si.area_name, 'area_kind', v_si.area_kind,
      'shift_id', v_si.shift_id, 'name', v_si.name, 'business_date', v_si.business_date,
      'production_date', v_si.production_date, 'starts_at', v_si.starts_at, 'ends_at', v_si.ends_at,
      'skipped', v_si.skipped_at is not null),
    'washroom', coalesce((
      select jsonb_agg(jsonb_build_object(
               'wash_group_id', w.wash_group_id, 'wash_group_name', g.name, 'wash_group_name_i18n', g.name_i18n,
               'loads_run', w.loads_run, 'standard_loads', w.standard_loads, 'rewash_loads', w.rewash_loads,
               'approximate', w.approximate)
             order by g.sort_order nulls last, g.name)
        from public.washroom_by_shift w
        left join public.wash_groups g on g.id = w.wash_group_id
       where w.shift_instance_id = v_si.id), '[]'::jsonb),
    'finishing', coalesce((
      select jsonb_agg(jsonb_build_object(
               'item_type_id', x.item_type_id, 'item_name', i.name, 'item_name_i18n', i.name_i18n,
               'wash_group_id', x.wash_group_id, 'packs', x.packs, 'loose_pieces', x.loose_pieces, 'pieces', x.pieces,
               'loads_approx', app.to_loads(null, x.item_type_id, x.pieces::numeric, 'piece'),
               'has_conversion', app.to_loads(null, x.item_type_id, x.pieces::numeric, 'piece') is not null,
               'by_line', x.by_line)
             order by i.sort_order, i.name)
        from (select f.item_type_id, f.wash_group_id,
                     sum(f.packs)::int as packs, sum(f.loose_pieces)::int as loose_pieces, sum(f.pieces)::int as pieces,
                     -- Line totals. Privacy note (review M1): a line run by one person makes its total that
                     -- person's output; shown because lines are equipment, but revisit with HR/legal.
                     jsonb_agg(jsonb_build_object('station_id', f.station_id, 'station_name', st.name,
                                                  'packs', f.packs, 'loose_pieces', f.loose_pieces, 'pieces', f.pieces)
                               order by st.name nulls first) as by_line
                from public.finished_by_shift f
                left join public.stations st on st.id = f.station_id
               where f.shift_instance_id = v_si.id
               group by f.item_type_id, f.wash_group_id) x
        join public.item_types i on i.id = x.item_type_id), '[]'::jsonb),
    'totals', jsonb_build_object(
      'loads_run',      coalesce((select sum(w.loads_run) from public.washroom_by_shift w where w.shift_instance_id = v_si.id), 0),
      'standard_loads', coalesce((select sum(w.standard_loads) from public.washroom_by_shift w where w.shift_instance_id = v_si.id), 0),
      'rewash_loads',   coalesce((select sum(w.rewash_loads) from public.washroom_by_shift w where w.shift_instance_id = v_si.id), 0),
      'pieces',         coalesce((select sum(f.pieces) from public.finished_by_shift f where f.shift_instance_id = v_si.id), 0)),
    -- Queue at shift end: completed in the shift window; remaining = open at its end (created before
    -- the end, still open now or completed after it). Cancelled items are not counted.
    'queue', jsonb_build_object(
      'completed', (select count(*) from public.queue_items q
                     where q.area_id = v_si.area_id and q.status = 'done'
                       and q.completed_at >= v_si.starts_at and q.completed_at < v_si.ends_at),
      'remaining', (select count(*) from public.queue_items q
                     where q.area_id = v_si.area_id and q.created_at < v_si.ends_at
                       and (q.status in ('queued', 'in_progress') or (q.status = 'done' and q.completed_at >= v_si.ends_at)))),
    -- Security review M1 (privacy): crew_count / labor_hours are NOT reported until HR/legal review.
    -- With a crew of 1 they are one person's hours next to that shift's output (per-worker data, §6.2 #11).
    'server_time', pg_catalog.now());
end;
$$;
comment on function public.get_shift_report(uuid) is
  'G1 shift report (owner/manager/lead/viewer; definer, role check first, plant-filtered). jsonb: {shift{id, area_id, area_name, area_kind, shift_id, name, business_date, production_date, starts_at, ends_at, skipped}, washroom[{wash_group_id, wash_group_name, wash_group_name_i18n, loads_run, standard_loads, rewash_loads, approximate}], finishing[{item_type_id, item_name, item_name_i18n, wash_group_id, packs, loose_pieces, pieces, loads_approx, has_conversion, by_line[{station_id, station_name, packs, loose_pieces, pieces}]}], totals{loads_run, standard_loads, rewash_loads, pieces}, queue{completed, remaining}, server_time}. No crew hours (privacy, pending HR/legal review). Voided rows excluded; off-shift rows are in the day report only. No per-person data. Errors: NOT_AUTHORIZED.';
revoke all on function public.get_shift_report(uuid) from public, anon;
grant execute on function public.get_shift_report(uuid) to authenticated, service_role;

-- ── get_day_report (G1 day report: washed vs finished per wash group per production day) ──
create function public.get_day_report(p_plant_id uuid, p_production_date date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_p         record;
  v_day_start timestamptz;
  v_day_end   timestamptz;
begin
  select p.id, p.timezone, p.production_day_start into v_p from public.plants p where p.id = p_plant_id;
  if v_p.id is null or not app.has_role(v_p.id, '{owner,manager,lead,viewer}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_day_report requires owner, manager, lead or viewer on the plant';
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
$$;
comment on function public.get_day_report(uuid, date) is
  'G1 day report (owner/manager/lead/viewer; definer, role check first, plant-filtered) for one PRODUCTION DAY (plants.production_day_start, default 12:00 → 12:00). jsonb: {plant_id, production_date, day_start, day_end, shifts[{id, area_id, area_name, area_kind, name, starts_at, ends_at}], reconciliation[{wash_group_id, wash_group_name, wash_group_name_i18n, ships_next_morning, est_loads_start, est_loads_end, loads_run, standard_loads, rewash_loads, pieces_finished, items_finished, pieces_without_conversion, finished_incomplete, loads_finished_approx, loads_finished_partial_approx, clean_backlog_loads_approx, approximate}], soil[{wash_group_id, wash_group_name, wash_group_name_i18n, est_loads_start, est_loads_end, has_conversion}], totals{loads_run, standard_loads, rewash_loads, pieces_finished}, off_shift{loads_run, standard_loads, pieces}, server_time}. Rows come from daily_reconciliation (voided rows excluded). No per-person data. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.get_day_report(uuid, date) from public, anon;
grant execute on function public.get_day_report(uuid, date) to authenticated, service_role;

-- ── get_wash_group_pace (G6 owner cards; actuals only, no goals yet) ──────
create function public.get_wash_group_pace(p_plant_id uuid, p_production_date date default null)
returns table (
  production_date                 date,
  wash_group_id                   uuid,
  wash_group_name                 text,
  wash_group_name_i18n            jsonb,
  color_hex                       text,
  sort_order                      int,
  ships_next_morning              boolean,
  loads_run                       int,       -- this production day, live cycles, rewash included
  standard_loads                  numeric,   -- this production day, first washes × load factor
  rewash_loads                    int,
  last_load_at                    timestamptz,
  estimate_qty                    numeric,   -- latest soil estimate (any day)
  estimate_unit                   app.qty_unit,
  estimate_loads                  numeric,   -- app.to_loads; null = no conversion (baskets without a factor)
  estimate_entered_at             timestamptz,
  estimate_age_minutes            int,
  estimate_freshness              text,      -- ok | amber | red (plant thresholds)
  standard_loads_since_estimate   numeric,   -- first-wash standard loads started after that estimate
  backlog_loads_approx            numeric,   -- ≈ estimate_loads − standard_loads_since_estimate (≥ 0); null without a conversion
  queue_open_items                int,       -- open items of this group in the plant's queues
  queue_loads_remaining           int,       -- Σ remaining loads of open items with a load count
  queue_items_without_load_count  int,       -- open piece/pack items (completed by hand)
  server_time                     timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_p    record;
  v_day  date;
  v_now  timestamptz := pg_catalog.now();
begin
  select p.id, p.timezone, p.production_day_start, p.estimate_amber_minutes, p.estimate_red_minutes
    into v_p from public.plants p where p.id = p_plant_id;
  if v_p.id is null or not app.has_role(v_p.id, '{owner,manager,lead,viewer}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_wash_group_pace requires owner, manager, lead or viewer on the plant';
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
$$;
comment on function public.get_wash_group_pace(uuid, date) is
  'G6 owner pace cards, actuals only (owner/manager/lead/viewer; definer, role check first, plant-filtered). One row per active wash group (plus inactive groups with loads that day), next-morning groups first: loads_run / standard_loads / rewash_loads for the production day (default: the current one), last_load_at, the latest soil estimate (qty, unit, estimate_loads via app.to_loads, age, freshness), standard_loads_since_estimate and backlog_loads_approx (≈, never below 0; null without a conversion), open queue items / remaining loads. Goals and alerts are later (G6: about 2 weeks after go-live). No per-person data. Errors: NOT_AUTHORIZED.';
revoke all on function public.get_wash_group_pace(uuid, date) from public, anon;
grant execute on function public.get_wash_group_pace(uuid, date) to authenticated, service_role;
