-- Owner decision 2026-11-01: reconciliation groups by PRODUCTION DAY, which runs from
-- plants.production_day_start (default 12:00) to the same local time next day, in the plant tz.
-- Example (America/New_York): washroom Evening Mon 14–24 + Night Tue 00–12, and finishing Evening
-- Mon 16–24 + Night Tue 00–10 + Day Tue 10–16 all belong to Monday's production day; washroom
-- Tue 14:00 starts Tuesday's.
--
-- shift_instances.business_date keeps its meaning (plant-local date the shift STARTS; used by
-- generation and the (shift_id, business_date) key). The new production_date is the production day
-- of the instance's start: ((starts_at at time zone tz) - production_day_start)::date.
--
-- History rule: when a plant's production_day_start (or timezone) changes, only instances that have
-- not started yet (starts_at > now()) are re-dated. Instances that already started keep the
-- production_date they had, so past reports never move.
-- Reporting views group by production_date; off-shift rows use the same formula on their timestamp.

-- ── plants.production_day_start ───────────────────────────────────────────
alter table public.plants
  add column production_day_start time not null default '12:00'
    constraint plants_production_day_start_whole_minutes check (extract(second from production_day_start) = 0);
comment on column public.plants.production_day_start is
  'Owner decision 2026-11-01: plant-local time the production day starts (default 12:00; whole minutes). A production day runs from this time to the same time the next day. Changing it re-dates only shift instances that have not started yet.';

-- ── The one production-day formula ────────────────────────────────────────
create function app.production_date(p_ts timestamptz, p_timezone text, p_day_start time)
returns date language sql stable parallel safe set search_path = '' as $$
  select ((p_ts at time zone p_timezone) - p_day_start::interval)::date;
$$;
comment on function app.production_date(timestamptz, text, time) is
  'Production day of p_ts: the plant-local date of (local time − production_day_start). With 12:00, Tue 11:59 local → Monday, Tue 12:00 → Tuesday. DST-safe (local wall time). Used by shift_instances.production_date and the reporting views.';
revoke all on function app.production_date(timestamptz, text, time) from public, anon;
grant execute on function app.production_date(timestamptz, text, time) to authenticated, service_role;

-- ── shift_instances.production_date ───────────────────────────────────────
alter table public.shift_instances add column production_date date;
comment on column public.shift_instances.production_date is
  'Production day of starts_at (app.production_date with the plant''s timezone and production_day_start). Set by trigger on insert / starts_at change; re-dated for not-yet-started instances when the plant setting changes. business_date is unchanged (local start date).';

-- One-time fill of existing rows (a derived value; the cloud project has no rows yet). The audit
-- trigger is paused for this statement only: these are not user edits.
alter table public.shift_instances disable trigger shift_instances_audit;
update public.shift_instances si
   set production_date = app.production_date(si.starts_at, p.timezone, p.production_day_start)
  from public.plants p
 where p.id = si.plant_id;
alter table public.shift_instances enable trigger shift_instances_audit;

alter table public.shift_instances alter column production_date set not null;
create index shift_instances_production_day_idx on public.shift_instances (plant_id, production_date, area_id);

-- Every insert path (generate_shift_instances, service role, tests) gets production_date from the
-- plant; a time change of a future instance by generation re-dates it.
create function app.set_production_date()
returns trigger language plpgsql set search_path = '' as $$
begin
  select app.production_date(new.starts_at, p.timezone, p.production_day_start)
    into new.production_date
    from public.plants p
   where p.id = new.plant_id;
  return new;   -- plant not found: the plant FK reports it
end;
$$;
comment on function app.set_production_date() is
  'BEFORE INSERT / UPDATE OF starts_at, plant_id on shift_instances: production_date = app.production_date(starts_at, plant timezone, plant production_day_start).';
create trigger shift_instances_set_production_date
  before insert or update of starts_at, plant_id on public.shift_instances
  for each row execute function app.set_production_date();

-- SECURITY DEFINER: plants UPDATE is owner-only (RLS); shift_instances have no client UPDATE
-- policy, so the re-date runs with the definer's rights, limited to the changed plant.
create function app.redate_future_shift_instances()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.shift_instances si
     set production_date = app.production_date(si.starts_at, new.timezone, new.production_day_start)
   where si.plant_id = new.id
     and si.starts_at > pg_catalog.now()
     and si.production_date is distinct from app.production_date(si.starts_at, new.timezone, new.production_day_start);
  return null;
end;
$$;
comment on function app.redate_future_shift_instances() is
  'AFTER UPDATE OF production_day_start, timezone on plants: recomputes production_date of the plant''s shift instances that have not started yet (starts_at > now()). Started instances keep theirs (history). Re-dates are audited by shift_instances_audit.';
create trigger plants_redate_future_shift_instances
  after update of production_day_start, timezone on public.plants
  for each row
  when (old.production_day_start is distinct from new.production_day_start or old.timezone is distinct from new.timezone)
  execute function app.redate_future_shift_instances();

-- ── Reporting views: group by production day ─────────────────────────────
-- Column business_date is renamed production_date (no client uses these views yet); the rename
-- keeps the views' grants and security_invoker option.
alter view public.washroom_by_shift rename column business_date to production_date;
create or replace view public.washroom_by_shift with (security_invoker = true) as
select w.org_id,
       w.plant_id,
       w.area_id,
       w.shift_instance_id,
       coalesce(si.production_date, app.production_date(w.started_at, p.timezone, p.production_day_start)) as production_date,
       w.item_type_id,
       sum(w.load_count)::int                          as loads
  from public.washer_cycles w
  join public.plants p on p.id = w.plant_id
  left join public.shift_instances si on si.id = w.shift_instance_id
 group by w.org_id, w.plant_id, w.area_id, w.shift_instance_id, 5, w.item_type_id;
comment on view public.washroom_by_shift is
  '§4.6 Loads washed per item per shift instance. production_date = the instance''s production day; off-shift rows (shift_instance_id null) use app.production_date(started_at) (plant production_day_start, default 12:00).';

alter view public.finished_by_shift rename column business_date to production_date;
create or replace view public.finished_by_shift with (security_invoker = true) as
select f.org_id,
       f.plant_id,
       f.area_id,
       f.shift_instance_id,
       coalesce(si.production_date, app.production_date(f.occurred_at, p.timezone, p.production_day_start)) as production_date,
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
 group by f.org_id, f.plant_id, f.area_id, f.shift_instance_id, 5, f.item_type_id, f.station_id;
comment on view public.finished_by_shift is
  '§4.6 Non-voided finished goods per item and line per shift instance; loads_approx = to_loads(pieces, ''piece'') (approximate, null without pieces_per_load). production_date = production day (instance, or app.production_date(occurred_at) off-shift).';

-- Estimate start/end: the latest estimate at/before the production day's first non-skipped
-- instance start / last instance end; without instances, the production-day bounds
-- (production_date + production_day_start, local) to the next day's.
alter view public.daily_reconciliation rename column business_date to production_date;
create or replace view public.daily_reconciliation with (security_invoker = true) as
with washed as (
  select w.org_id, w.plant_id,
         coalesce(si.production_date, app.production_date(w.started_at, p.timezone, p.production_day_start)) as production_date,
         w.item_type_id,
         sum(w.load_count)::numeric as loads_washed
    from public.washer_cycles w
    join public.plants p on p.id = w.plant_id
    left join public.shift_instances si on si.id = w.shift_instance_id
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
         coalesce(w.loads_washed, 0)                    as loads_washed,
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
  '§4.6/G1 Washroom vs finishing per item per PRODUCTION DAY (production_date; plants.production_day_start, default 12:00 → 12:00 local). Rows on an instance use its production_date; off-shift rows use app.production_date(timestamp). loads_finished_approx = to_loads(pieces, ''piece''); null and has_conversion=false without pieces_per_load. estimate_error_pct stays null until the owner approves its formula.';
