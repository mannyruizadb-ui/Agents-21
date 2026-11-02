-- Owner decision 2026-11-02 (C): rewash loads. A rewash is a load of goods that were already washed
-- (formula 5 includes "rewash whites"), so it is washroom WORK but not NEW goods: it must not count
-- toward washed-vs-finished reconciliation.
--
--   * washer_cycles.is_rewash boolean not null default false. Set by whoever records the cycle
--     (existing insert policy: owner/manager/lead, manual only). washer_cycles has no client UPDATE
--     policy, so the flag cannot be flipped after the fact by a client.
--
-- One definition, used by both views (chosen here, documented in each view comment):
--   * loads_run      = sum(load_count) over ALL cycles, rewash included (raw washer work).
--   * rewash_loads   = sum(load_count) over rewash cycles only (raw).
--   * standard_loads = sum(load_count × load_factor_used) over NON-rewash cycles only (new goods washed,
--                      in standard loads). So standard_loads means the same thing in washroom_by_shift and
--                      daily_reconciliation, and the reconciliation backlog never counts a rewash.
--   * washroom_by_shift.approximate is now taken over the non-rewash cycles (the ones standard_loads covers).
--
-- Views are replaced with CREATE OR REPLACE: existing columns keep their names, order and types, and
-- rewash_loads is appended at the end. Grants are kept and restated below.

alter table public.washer_cycles
  add column is_rewash boolean not null default false;
comment on column public.washer_cycles.is_rewash is
  'Owner 2026-11-02: true = a rewash of goods that were already washed. Counted in loads_run and rewash_loads, never in standard_loads, so reconciliation compares finished goods with first washes only.';

create or replace view public.washroom_by_shift with (security_invoker = true) as
select w.org_id,
       w.plant_id,
       w.area_id,
       w.shift_instance_id,
       coalesce(si.production_date, app.production_date(w.started_at, p.timezone, p.production_day_start)) as production_date,
       w.wash_group_id,
       sum(w.load_count)::int                                                              as loads_run,
       coalesce(sum(w.load_count * w.load_factor_used) filter (where not w.is_rewash), 0)::numeric as standard_loads,
       coalesce(bool_or(w.load_factor_used <> 1) filter (where not w.is_rewash), false)    as approximate,
       coalesce(sum(w.load_count) filter (where w.is_rewash), 0)::int                      as rewash_loads
  from public.washer_cycles w
  join public.plants p on p.id = w.plant_id
  left join public.shift_instances si on si.id = w.shift_instance_id
 group by w.org_id, w.plant_id, w.area_id, w.shift_instance_id, 5, w.wash_group_id;
comment on view public.washroom_by_shift is
  '§4.6 Washroom per wash group per shift instance (wash_group_id null = unmapped formula). loads_run = sum(load_count) over ALL cycles (rewash included, raw washer work); rewash_loads = sum(load_count) of rewash cycles (raw); standard_loads = sum(load_count × load_factor_used) over NON-rewash cycles only (new goods washed; the machine''s factor snapshotted at insert, 1 without machine); approximate = some non-rewash load had a factor ≠ 1. production_date = production day (instance, or app.production_date(started_at) off-shift).';

-- Same body as 20261101214357, with the rewash split in "washed" / "keyed" and rewash_loads appended.
create or replace view public.daily_reconciliation with (security_invoker = true) as
with washed as (
  select w.org_id, w.plant_id,
         coalesce(si.production_date, app.production_date(w.started_at, p.timezone, p.production_day_start)) as production_date,
         w.wash_group_id,
         sum(w.load_count)::numeric                                                       as loads_run,
         coalesce(sum(w.load_count * w.load_factor_used) filter (where not w.is_rewash), 0)::numeric as standard_loads,
         coalesce(sum(w.load_count) filter (where w.is_rewash), 0)::numeric               as rewash_loads
    from public.washer_cycles w
    join public.plants p on p.id = w.plant_id
    left join public.shift_instances si on si.id = w.shift_instance_id
   where w.wash_group_id is not null
   group by 1, 2, 3, 4
), finished_items as (
  select f.org_id, f.plant_id,
         coalesce(si.production_date, app.production_date(f.occurred_at, p.timezone, p.production_day_start)) as production_date,
         f.wash_group_id,
         f.item_type_id,
         sum(f.pieces)::numeric as pieces
    from public.finished_goods_entries f
    join public.plants p on p.id = f.plant_id
    left join public.shift_instances si on si.id = f.shift_instance_id
   where f.voided_at is null
   group by 1, 2, 3, 4, 5
), finished as (
  select fi.org_id, fi.plant_id, fi.production_date, fi.wash_group_id,
         sum(fi.pieces)                                                   as pieces_finished,
         count(*)::int                                                    as items_finished,
         coalesce(sum(fi.pieces) filter (where c.loads is null), 0)::int  as pieces_without_conversion,
         coalesce(sum(c.loads), 0)                                        as loads_converted
    from finished_items fi
    cross join lateral (select app.to_loads(null, fi.item_type_id, fi.pieces, 'piece') as loads) c
   group by 1, 2, 3, 4
), keyed as (
  select coalesce(w.org_id, f.org_id)                   as org_id,
         coalesce(w.plant_id, f.plant_id)               as plant_id,
         coalesce(w.production_date, f.production_date) as production_date,
         coalesce(w.wash_group_id, f.wash_group_id)     as wash_group_id,
         coalesce(w.loads_run, 0)                       as loads_run,
         coalesce(w.standard_loads, 0)                  as standard_loads,
         coalesce(w.rewash_loads, 0)                    as rewash_loads,
         coalesce(f.pieces_finished, 0)                 as pieces_finished,
         coalesce(f.items_finished, 0)                  as items_finished,
         coalesce(f.pieces_without_conversion, 0)       as pieces_without_conversion,
         coalesce(f.loads_converted, 0)                 as loads_converted
    from washed w
    full join finished f
      on f.plant_id = w.plant_id and f.production_date = w.production_date and f.wash_group_id = w.wash_group_id
)
select k.org_id,
       k.plant_id,
       k.production_date,
       k.wash_group_id,
       g.name                                                  as wash_group_name,
       g.name_i18n                                             as wash_group_name_i18n,
       est_start.qty_loads                                     as est_loads_start,
       k.loads_run,
       k.standard_loads,
       k.pieces_finished,
       k.items_finished,
       k.pieces_without_conversion,
       k.pieces_without_conversion > 0                         as finished_incomplete,
       k.loads_converted                                       as loads_finished_partial_approx,
       case when k.pieces_without_conversion = 0 then k.loads_converted end                     as loads_finished_approx,
       case when k.pieces_without_conversion = 0 then k.standard_loads - k.loads_converted end  as clean_backlog_loads_approx,
       est_end.qty_loads                                       as est_loads_end,
       null::numeric                                           as estimate_error_pct,
       true                                                    as approximate,
       k.rewash_loads
  from keyed k
  join public.plants p on p.id = k.plant_id
  join public.wash_groups g on g.id = k.wash_group_id
  cross join lateral (
    select coalesce(min(si.starts_at), (k.production_date + p.production_day_start) at time zone p.timezone)     as day_start,
           coalesce(max(si.ends_at), ((k.production_date + 1) + p.production_day_start) at time zone p.timezone) as day_end
      from public.shift_instances si
     where si.plant_id = k.plant_id and si.production_date = k.production_date and si.skipped_at is null
  ) b
  left join lateral (
    select app.to_loads(e.wash_group_id, null, e.qty, e.unit) as qty_loads
      from public.soil_estimates e
     where e.plant_id = k.plant_id and e.wash_group_id = k.wash_group_id and e.entered_at <= b.day_start
     order by e.entered_at desc, e.id desc
     limit 1
  ) est_start on true
  left join lateral (
    select app.to_loads(e.wash_group_id, null, e.qty, e.unit) as qty_loads
      from public.soil_estimates e
     where e.plant_id = k.plant_id and e.wash_group_id = k.wash_group_id and e.entered_at <= b.day_end
     order by e.entered_at desc, e.id desc
     limit 1
  ) est_end on true;
comment on view public.daily_reconciliation is
  '§4.6/G1 Washroom vs finishing per WASH GROUP per PRODUCTION DAY (owner 2026-11-01). loads_run = sum(load_count) over ALL cycles (rewash included); rewash_loads = sum(load_count) of rewash cycles (owner 2026-11-02); standard_loads = sum(load_count × load_factor_used) over NON-rewash cycles only, so a rewash never counts as goods washed. loads_finished_approx = Σ over the group''s items of to_loads(pieces, ''piece''); it and clean_backlog_loads_approx (= standard_loads − loads_finished_approx) are null when finished_incomplete (some finished pieces have no pieces_per_load: see pieces_without_conversion; loads_finished_partial_approx = sum over the items that convert). Finished goods count in the wash group snapshotted on each entry and washer loads at the load factor snapshotted on each cycle, so later catalog/machine edits never rewrite history. approximate is always true. estimate_error_pct stays null until the owner approves its formula.';

revoke all on public.washroom_by_shift, public.daily_reconciliation from anon, authenticated;
grant select on public.washroom_by_shift, public.daily_reconciliation to authenticated;
