-- Plant holidays (owner 2026-11-05): the plant is closed only on Christmas Day, New Year's Day and
-- Thanksgiving Day. Holidays are DATA (rules the owner can edit later), not code:
--
-- * public.plant_holidays: per plant, a yearly rule. Either a fixed date (month + day: Dec 25, Jan 1)
--   or the nth weekday of a month (month + weekday 0=Sun..6=Sat + nth 1..5, or -1 = last: Thanksgiving
--   = 4th Thursday of November). Read by every plant role; insert/update by the owner only; no
--   deletes (deactivate). Audited.
-- * app.is_plant_closed(plant, date): true when an active rule matches that plant-local date.
-- * app.generate_shift_instances no longer creates instances whose business date (the day the shift
--   STARTS) is a holiday, and marks unreferenced future instances on a holiday as skipped (never
--   deleted). A shift that starts the evening before and runs past midnight still runs. Removing a
--   rule later does not un-skip an instance (the owner can use set_shift_skipped).
-- * DATA: the 3 rules for the ADB plant (seed.sql has the same), and future, unreferenced instances
--   already generated on those dates (e.g. Thanksgiving 2026-11-26) are marked skipped now.

create table public.plant_holidays (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  plant_id    uuid not null,
  name        text not null check (char_length(name) between 1 and 60 and app.is_clean_text(name)),
  name_i18n   jsonb not null default '{}'::jsonb check (jsonb_typeof(name_i18n) = 'object'),
  month       smallint not null check (month between 1 and 12),
  day         smallint check (day between 1 and 31),
  weekday     smallint check (weekday between 0 and 6),
  nth         smallint check (nth in (-1, 1, 2, 3, 4, 5)),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  unique (plant_id, name),
  constraint plant_holidays_rule check (
    (day is not null and weekday is null and nth is null)
    or (day is null and weekday is not null and nth is not null))
);
alter table public.plant_holidays enable row level security;
create index plant_holidays_plant_org_idx on public.plant_holidays (plant_id, org_id);
comment on table public.plant_holidays is
  'Owner 2026-11-05: yearly days the plant is closed (no shift instances). Fixed date (month + day) or nth weekday of a month (month + weekday 0=Sun + nth 1..5 / -1 last). Owner-edited; deactivate, never delete.';

create trigger plant_holidays_touch_updated_at before update on public.plant_holidays
  for each row execute function app.touch_updated_at();
create trigger plant_holidays_audit after insert or update on public.plant_holidays
  for each row execute function app.audit();

create policy plant_holidays_select on public.plant_holidays for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')));
create policy plant_holidays_insert on public.plant_holidays for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner}')));
create policy plant_holidays_update on public.plant_holidays for update to authenticated
  using ((select app.has_role(plant_id, '{owner}')))
  with check ((select app.has_role(plant_id, '{owner}')));
revoke all on public.plant_holidays from anon, authenticated;
grant select on public.plant_holidays to authenticated;
grant insert (org_id, plant_id, name, name_i18n, month, day, weekday, nth, active) on public.plant_holidays to authenticated;
grant update (name, name_i18n, month, day, weekday, nth, active) on public.plant_holidays to authenticated;

create function app.is_plant_closed(p_plant_id uuid, p_date date)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.plant_holidays h
     where h.plant_id = p_plant_id and h.active
       and h.month = extract(month from p_date)::int
       and (   (h.day is not null and h.day = extract(day from p_date)::int)
            or (h.day is null and h.weekday = extract(dow from p_date)::int
                and (   (h.nth > 0 and (extract(day from p_date)::int - 1) / 7 + 1 = h.nth)
                     or (h.nth = -1 and extract(month from p_date + 7) <> extract(month from p_date))))));
$$;
comment on function app.is_plant_closed(uuid, date) is
  'Owner 2026-11-05: true when an active plant_holidays rule of the plant matches the plant-local date (fixed month/day, or the nth / last weekday of the month).';
revoke all on function app.is_plant_closed(uuid, date) from public, anon, authenticated;
grant execute on function app.is_plant_closed(uuid, date) to service_role;

CREATE OR REPLACE FUNCTION app.generate_shift_instances(p_plant_id uuid, p_days integer, p_from date DEFAULT NULL::date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tz    text;
  v_from  date;
  v_count int;
begin
  if p_plant_id is null or p_days is null or p_days not between 1 and 60 then
    raise exception 'VALIDATION_FAILED' using detail = 'p_days: must be between 1 and 60; p_plant_id required';
  end if;
  select p.timezone into v_tz from public.plants p where p.id = p_plant_id;
  if v_tz is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_plant_id: plant not found';
  end if;
  v_from := coalesce(p_from, (pg_catalog.now() at time zone v_tz)::date);

  with candidates as (
    select s.org_id, s.plant_id, s.area_id, s.id as shift_id,
           (v_from + g.n) as business_date,
           ((v_from + g.n) + s.start_local) at time zone v_tz as starts_at,
           ((v_from + g.n + case when s.end_local <= s.start_local then 1 else 0 end) + s.end_local)
             at time zone v_tz as ends_at
      from public.shifts s
     cross join pg_catalog.generate_series(0, p_days - 1) as g(n)
     where s.plant_id = p_plant_id
       and s.active
       and extract(dow from (v_from + g.n))::smallint = any (s.days_of_week)
       and not app.is_plant_closed(p_plant_id, v_from + g.n)          -- holidays (owner 2026-11-05)
  ), upserted as (
    insert into public.shift_instances as si (org_id, plant_id, area_id, shift_id, business_date, starts_at, ends_at)
    select c.org_id, c.plant_id, c.area_id, c.shift_id, c.business_date, c.starts_at, c.ends_at
      from candidates c
     order by c.starts_at
    on conflict (shift_id, business_date) do update
       set starts_at = excluded.starts_at,
           ends_at   = excluded.ends_at
     where si.starts_at > pg_catalog.now()
       and (si.starts_at, si.ends_at) is distinct from (excluded.starts_at, excluded.ends_at)
       and not exists (select 1 from public.finished_goods_entries f where f.shift_instance_id = si.id)
       and not exists (select 1 from public.washer_cycles w where w.shift_instance_id = si.id)
       and not exists (select 1 from public.shift_crew_hours h where h.shift_instance_id = si.id)
       and not exists (select 1 from public.alert_events a where a.shift_instance_id = si.id)
    returning 1
  )
  select count(*)::int into v_count from upserted;

  -- Architect N1c: unreferenced future instances whose shift is now inactive, or no longer runs
  -- on that weekday, are marked "didn't run" (never deleted).
  with retired as (
    update public.shift_instances si
       set skipped_at = pg_catalog.now()
      from public.shifts s
     where s.id = si.shift_id
       and si.plant_id = p_plant_id
       and si.skipped_at is null
       and si.starts_at > pg_catalog.now()
       and (not s.active or not (extract(dow from si.business_date)::smallint = any (s.days_of_week))
            or app.is_plant_closed(si.plant_id, si.business_date))
       and not exists (select 1 from public.finished_goods_entries f where f.shift_instance_id = si.id)
       and not exists (select 1 from public.washer_cycles w where w.shift_instance_id = si.id)
       and not exists (select 1 from public.shift_crew_hours h where h.shift_instance_id = si.id)
       and not exists (select 1 from public.alert_events a where a.shift_instance_id = si.id)
    returning 1
  )
  select v_count + count(*)::int into v_count from retired;
  return v_count;
end;
$function$;
comment on function app.generate_shift_instances(uuid, int, date) is
  'A6/D6: creates shift_instances for p_days (1–60) days from p_from (default plant-local today), per active shift and day of week (0=Sun), except on the plant''s holidays (plant_holidays; owner 2026-11-05). DST-safe via AT TIME ZONE. Idempotent; updates times only of unreferenced future instances, and marks unreferenced future instances of inactive shifts / removed weekdays / holidays as skipped. Returns rows inserted, updated or skipped. service_role/postgres only.';

-- ── DATA: ADB holidays, and instances already generated on them ───────────
insert into public.plant_holidays (org_id, plant_id, name, name_i18n, month, day, weekday, nth)
select p.org_id, p.id, v.name, v.name_i18n, v.month, v.day, v.weekday, v.nth
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
   ('Christmas Day',    '{"es":"Navidad"}'::jsonb,            12::smallint, 25::smallint, null::smallint, null::smallint),
   ('New Year''s Day',  '{"es":"Año Nuevo"}'::jsonb,           1,           1,            null,           null),
   ('Thanksgiving Day', '{"es":"Día de Acción de Gracias"}'::jsonb, 11,     null,         4,              4)) as v(name, name_i18n, month, day, weekday, nth)
 where p.name = 'Miami'
on conflict (plant_id, name) do nothing;

update public.shift_instances si
   set skipped_at = pg_catalog.now()
 where si.skipped_at is null
   and si.starts_at > pg_catalog.now()
   and app.is_plant_closed(si.plant_id, si.business_date)
   and not exists (select 1 from public.finished_goods_entries f where f.shift_instance_id = si.id)
   and not exists (select 1 from public.washer_cycles w where w.shift_instance_id = si.id)
   and not exists (select 1 from public.shift_crew_hours h where h.shift_instance_id = si.id)
   and not exists (select 1 from public.alert_events a where a.shift_instance_id = si.id);
