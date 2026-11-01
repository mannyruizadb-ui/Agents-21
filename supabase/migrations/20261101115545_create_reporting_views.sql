-- M1 · reporting views (PRD §4.6, G1). All views are security_invoker, so the caller's RLS on the
-- underlying tables applies (a display sees no finished-goods / washer rows; other tenants see nothing).
-- Conversions go only through app.to_loads(); finished goods convert from pieces ('piece', never
-- 'pack'), and piece-based results are flagged approximate (extra c).
-- D9 business date: the row's shift instance business_date; off-shift rows (no instance) use the
-- plant-local calendar date of their timestamp. No production-day-start setting yet (owner pending).

create view public.current_soil_estimates with (security_invoker = true) as
select distinct on (e.plant_id, e.item_type_id)
       e.org_id,
       e.plant_id,
       e.item_type_id,
       e.id                                            as estimate_id,
       e.qty,
       e.unit,
       app.to_loads(e.item_type_id, e.qty, e.unit)     as qty_loads,
       app.to_loads(e.item_type_id, e.qty, e.unit) is not null as has_conversion,
       e.entered_at,
       e.entered_by,
       e.staff_id,
       st.display_name                                 as entered_by_name,   -- null unless caller may read entry staff
       floor(extract(epoch from (now() - e.entered_at)) / 60)::int as age_minutes,
       case
         when now() - e.entered_at >= make_interval(mins => p.estimate_red_minutes)   then 'red'
         when now() - e.entered_at >= make_interval(mins => p.estimate_amber_minutes) then 'amber'
         else 'ok'
       end                                             as freshness
  from public.soil_estimates e
  join public.plants p on p.id = e.plant_id
  left join public.entry_staff st on st.id = e.staff_id
 order by e.plant_id, e.item_type_id, e.entered_at desc, e.id desc;
comment on view public.current_soil_estimates is
  '§4.6 Latest soil estimate per item with load equivalent (null = no conversion), age and freshness (ok/amber/red per plant thresholds).';

create view public.queue_board with (security_invoker = true) as
select q.org_id,
       q.plant_id,
       q.area_id,
       q.id,
       q.position,
       q.is_rush,
       q.status,
       q.qty,
       q.unit,
       app.to_loads(q.item_type_id, q.qty, q.unit)     as qty_loads,
       q.unit in ('piece', 'pack')                     as approximate,
       q.item_type_id,
       i.name                                          as item_name,
       i.name_i18n                                     as item_name_i18n,
       i.color_hex                                     as item_color_hex,
       q.note,
       q.version,
       q.started_at,
       q.created_at
  from public.queue_items q
  join public.item_types i on i.id = q.item_type_id
 where q.status in ('queued', 'in_progress');
comment on view public.queue_board is
  '§4.6 Open queue (queued/in_progress) per area with item names in all languages; order by is_rush desc, position asc.';

create view public.washroom_by_shift with (security_invoker = true) as
select w.org_id,
       w.plant_id,
       w.area_id,
       w.shift_instance_id,
       coalesce(si.business_date, (w.started_at at time zone p.timezone)::date) as business_date,
       w.item_type_id,
       sum(w.load_count)::int                          as loads
  from public.washer_cycles w
  join public.plants p on p.id = w.plant_id
  left join public.shift_instances si on si.id = w.shift_instance_id
 group by w.org_id, w.plant_id, w.area_id, w.shift_instance_id,
          coalesce(si.business_date, (w.started_at at time zone p.timezone)::date), w.item_type_id;
comment on view public.washroom_by_shift is
  '§4.6 Loads washed per item per shift instance (shift_instance_id null = off-shift, dated per D9).';

create view public.finished_by_shift with (security_invoker = true) as
select f.org_id,
       f.plant_id,
       f.area_id,
       f.shift_instance_id,
       coalesce(si.business_date, (f.occurred_at at time zone p.timezone)::date) as business_date,
       f.item_type_id,
       f.station_id,
       sum(f.packs)::int                               as packs,
       sum(f.loose_pieces)::int                        as loose_pieces,
       sum(f.pieces)::int                              as pieces,
       app.to_loads(f.item_type_id, sum(f.pieces)::numeric, 'piece') as loads_approx,
       true                                            as approximate,
       app.to_loads(f.item_type_id, sum(f.pieces)::numeric, 'piece') is not null as has_conversion
  from public.finished_goods_entries f
  join public.plants p on p.id = f.plant_id
  left join public.shift_instances si on si.id = f.shift_instance_id
 where f.voided_at is null
 group by f.org_id, f.plant_id, f.area_id, f.shift_instance_id,
          coalesce(si.business_date, (f.occurred_at at time zone p.timezone)::date), f.item_type_id, f.station_id;
comment on view public.finished_by_shift is
  '§4.6 Non-voided finished goods per item and line per shift instance; loads_approx = to_loads(pieces, ''piece'') (approximate, null without pieces_per_load).';

-- Washroom vs finishing per item per business date (v1.3). Estimate start/end: the latest estimate
-- at/before the business day's first non-skipped instance start / last instance end (plant-local
-- midnight bounds when the day has no instances). estimate_error_pct stays null until the owner
-- settles the production-day start and its formula.
create view public.daily_reconciliation with (security_invoker = true) as
with washed as (
  select w.org_id, w.plant_id,
         coalesce(si.business_date, (w.started_at at time zone p.timezone)::date) as business_date,
         w.item_type_id,
         sum(w.load_count)::numeric as loads_washed
    from public.washer_cycles w
    join public.plants p on p.id = w.plant_id
    left join public.shift_instances si on si.id = w.shift_instance_id
   where w.item_type_id is not null
   group by 1, 2, 3, 4
), finished as (
  select f.org_id, f.plant_id,
         coalesce(si.business_date, (f.occurred_at at time zone p.timezone)::date) as business_date,
         f.item_type_id,
         sum(f.pieces)::numeric as pieces_finished
    from public.finished_goods_entries f
    join public.plants p on p.id = f.plant_id
    left join public.shift_instances si on si.id = f.shift_instance_id
   where f.voided_at is null
   group by 1, 2, 3, 4
), keyed as (
  select coalesce(w.org_id, f.org_id)               as org_id,
         coalesce(w.plant_id, f.plant_id)           as plant_id,
         coalesce(w.business_date, f.business_date) as business_date,
         coalesce(w.item_type_id, f.item_type_id)   as item_type_id,
         coalesce(w.loads_washed, 0)                as loads_washed,
         coalesce(f.pieces_finished, 0)             as pieces_finished
    from washed w
    full join finished f
      on f.plant_id = w.plant_id and f.business_date = w.business_date and f.item_type_id = w.item_type_id
)
select k.org_id,
       k.plant_id,
       k.business_date,
       k.item_type_id,
       i.name                                                  as item_name,
       i.name_i18n                                             as item_name_i18n,
       est_start.qty_loads                                     as est_loads_start,
       k.loads_washed,
       k.pieces_finished,
       i.pieces_per_load,
       app.to_loads(k.item_type_id, k.pieces_finished, 'piece') as loads_finished_approx,
       k.loads_washed - app.to_loads(k.item_type_id, k.pieces_finished, 'piece') as clean_backlog_loads_approx,
       est_end.qty_loads                                       as est_loads_end,
       null::numeric                                           as estimate_error_pct,
       i.pieces_per_load is not null                           as has_conversion,
       true                                                    as approximate
  from keyed k
  join public.plants p on p.id = k.plant_id
  join public.item_types i on i.id = k.item_type_id
  cross join lateral (
    select coalesce(min(si.starts_at), (k.business_date::timestamp) at time zone p.timezone)     as day_start,
           coalesce(max(si.ends_at), ((k.business_date + 1)::timestamp) at time zone p.timezone) as day_end
      from public.shift_instances si
     where si.plant_id = k.plant_id and si.business_date = k.business_date and si.skipped_at is null
  ) b
  left join lateral (
    select app.to_loads(e.item_type_id, e.qty, e.unit) as qty_loads
      from public.soil_estimates e
     where e.plant_id = k.plant_id and e.item_type_id = k.item_type_id and e.entered_at <= b.day_start
     order by e.entered_at desc, e.id desc
     limit 1
  ) est_start on true
  left join lateral (
    select app.to_loads(e.item_type_id, e.qty, e.unit) as qty_loads
      from public.soil_estimates e
     where e.plant_id = k.plant_id and e.item_type_id = k.item_type_id and e.entered_at <= b.day_end
     order by e.entered_at desc, e.id desc
     limit 1
  ) est_end on true;
comment on view public.daily_reconciliation is
  '§4.6/G1 Washroom vs finishing per item per business date (D9). loads_finished_approx = to_loads(pieces, ''piece''); null and has_conversion=false without pieces_per_load. estimate_error_pct is null until the production-day start is decided (owner).';

revoke all on public.current_soil_estimates, public.queue_board, public.washroom_by_shift,
              public.finished_by_shift, public.daily_reconciliation from anon, authenticated;
grant select on public.current_soil_estimates, public.queue_board, public.washroom_by_shift,
               public.finished_by_shift, public.daily_reconciliation to authenticated;
