-- Owner decision 2026-11-01: washers are not all the same size. A machine's load_factor says how
-- many standard loads one of its loads is (Washer 6 is filled to its larger size: ≈ 1.19). It is a
-- unitless ratio; PlantBoard never weighs anything.
-- Washroom totals become two numbers:
--   loads_run      = sum(load_count)                                    (what was actually run)
--   standard_loads = sum(load_count × coalesce(machine.load_factor, 1)) (comparable across machines)
-- Reconciliation compares finished goods (app.to_loads, unchanged) with standard_loads.
-- A cycle without machine_id counts at factor 1.
-- Note: the factor is read at report time, so editing it changes past standard_loads too (audited
-- via machines_audit). Snapshotting it per cycle is an open owner/architect question.

alter table public.machines
  add column load_factor numeric(4,2) not null default 1.00
    constraint machines_load_factor_range check (load_factor between 0.25 and 4.00);
comment on column public.machines.load_factor is
  'Standard loads per load run on this machine (unitless, 0.25–4.00, default 1.00). Washroom standard_loads = load_count × load_factor. Owner/manager editable (machines RLS); audited.';

-- ── Reporting views: loads_run + standard_loads ───────────────────────────
-- Column lists change (loads → loads_run, loads_washed → loads_run, + standard_loads), so the two
-- views are dropped and recreated with the same options and grants. No client uses them yet.
drop view public.washroom_by_shift;
create view public.washroom_by_shift with (security_invoker = true) as
select w.org_id,
       w.plant_id,
       w.area_id,
       w.shift_instance_id,
       coalesce(si.production_date, app.production_date(w.started_at, p.timezone, p.production_day_start)) as production_date,
       w.item_type_id,
       sum(w.load_count)::int                                     as loads_run,
       sum(w.load_count * coalesce(m.load_factor, 1))::numeric     as standard_loads,
       coalesce(bool_or(coalesce(m.load_factor, 1) <> 1), false)   as approximate
  from public.washer_cycles w
  join public.plants p on p.id = w.plant_id
  left join public.shift_instances si on si.id = w.shift_instance_id
  left join public.machines m on m.id = w.machine_id
 group by w.org_id, w.plant_id, w.area_id, w.shift_instance_id, 5, w.item_type_id;
comment on view public.washroom_by_shift is
  '§4.6 Washroom per item per shift instance: loads_run = sum(load_count); standard_loads = sum(load_count × machine load_factor, 1 without machine); approximate = some load had a factor ≠ 1. production_date = production day (instance, or app.production_date(started_at) off-shift).';

drop view public.daily_reconciliation;
create view public.daily_reconciliation with (security_invoker = true) as
with washed as (
  select w.org_id, w.plant_id,
         coalesce(si.production_date, app.production_date(w.started_at, p.timezone, p.production_day_start)) as production_date,
         w.item_type_id,
         sum(w.load_count)::numeric                          as loads_run,
         sum(w.load_count * coalesce(m.load_factor, 1))::numeric as standard_loads
    from public.washer_cycles w
    join public.plants p on p.id = w.plant_id
    left join public.shift_instances si on si.id = w.shift_instance_id
    left join public.machines m on m.id = w.machine_id
   where w.item_type_id is not null
   group by 1, 2, 3, 4
), finished as (
  select f.org_id, f.plant_id,
         coalesce(si.production_date, app.production_date(f.occurred_at, p.timezone, p.production_day_start)) as production_date,
         f.item_type_id,
         sum(f.pieces)::numeric as pieces_finished
    from public.finished_goods_entries f
    join public.plants p on p.id = f.plant_id
    left join public.shift_instances si on si.id = f.shift_instance_id
   where f.voided_at is null
   group by 1, 2, 3, 4
), keyed as (
  select coalesce(w.org_id, f.org_id)                   as org_id,
         coalesce(w.plant_id, f.plant_id)               as plant_id,
         coalesce(w.production_date, f.production_date) as production_date,
         coalesce(w.item_type_id, f.item_type_id)       as item_type_id,
         coalesce(w.loads_run, 0)                       as loads_run,
         coalesce(w.standard_loads, 0)                  as standard_loads,
         coalesce(f.pieces_finished, 0)                 as pieces_finished
    from washed w
    full join finished f
      on f.plant_id = w.plant_id and f.production_date = w.production_date and f.item_type_id = w.item_type_id
)
select k.org_id,
       k.plant_id,
       k.production_date,
       k.item_type_id,
       i.name                                                  as item_name,
       i.name_i18n                                             as item_name_i18n,
       est_start.qty_loads                                     as est_loads_start,
       k.loads_run,
       k.standard_loads,
       k.pieces_finished,
       i.pieces_per_load,
       app.to_loads(k.item_type_id, k.pieces_finished, 'piece') as loads_finished_approx,
       k.standard_loads - app.to_loads(k.item_type_id, k.pieces_finished, 'piece') as clean_backlog_loads_approx,
       est_end.qty_loads                                       as est_loads_end,
       null::numeric                                           as estimate_error_pct,
       i.pieces_per_load is not null                           as has_conversion,
       true                                                    as approximate
  from keyed k
  join public.plants p on p.id = k.plant_id
  join public.item_types i on i.id = k.item_type_id
  cross join lateral (
    select coalesce(min(si.starts_at), (k.production_date + p.production_day_start) at time zone p.timezone)     as day_start,
           coalesce(max(si.ends_at), ((k.production_date + 1) + p.production_day_start) at time zone p.timezone) as day_end
      from public.shift_instances si
     where si.plant_id = k.plant_id and si.production_date = k.production_date and si.skipped_at is null
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
  '§4.6/G1 Washroom vs finishing per item per PRODUCTION DAY (production_date; plants.production_day_start, default 12:00 → 12:00 local). loads_run = sum(load_count); standard_loads = sum(load_count × machine load_factor). loads_finished_approx = to_loads(pieces, ''piece''); clean_backlog_loads_approx = standard_loads − loads_finished_approx. approximate is always true (pieces_per_load and load_factor are approximations). estimate_error_pct stays null until the owner approves its formula.';

revoke all on public.washroom_by_shift, public.daily_reconciliation from anon, authenticated;
grant select on public.washroom_by_shift, public.daily_reconciliation to authenticated;
