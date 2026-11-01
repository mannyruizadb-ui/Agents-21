-- M1 · shifts, shift instances, entry staff + PIN sessions (PRD A6, A8; §4.4; §4.5; §5.3).
-- Binding decisions D2–D7, D12 (M1 plan review) are cited inline.

-- ── Shifts (A6: per area; day-specific variants are separate rows with the same name) ──
create table public.shifts (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  area_id       uuid not null,
  name          text not null check (char_length(name) between 1 and 40 and app.is_clean_text(name)),
  start_local   time not null,
  end_local     time not null,                            -- end <= start ⇒ crosses midnight (00:00 = 24:00)
  days_of_week  smallint[] not null check (days_of_week <@ array[0,1,2,3,4,5,6]::smallint[]
                                           and cardinality(days_of_week) > 0),   -- 0 = Sunday, day it STARTS
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (area_id, plant_id) references public.areas(id, plant_id),
  unique (id, plant_id),
  unique (id, area_id),
  check (start_local <> end_local)
);
alter table public.shifts enable row level security;
create index shifts_plant_org_idx on public.shifts (plant_id, org_id);
create index shifts_area_plant_idx on public.shifts (area_id, plant_id);

create table public.shift_instances (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  area_id       uuid not null,
  shift_id      uuid not null,
  business_date date not null,                            -- local date the shift starts
  starts_at     timestamptz not null,                     -- computed with AT TIME ZONE (DST-safe)
  ends_at       timestamptz not null check (ends_at > starts_at),
  skipped_at    timestamptz,                              -- (P1) "didn't run" (holiday)
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (shift_id, plant_id) references public.shifts(id, plant_id),
  foreign key (shift_id, area_id) references public.shifts(id, area_id),  -- instance area = shift area
  unique (id, plant_id),
  unique (id, area_id),                                   -- target for area-consistent FKs
  unique (shift_id, business_date),
  -- D7: no overlap per AREA (not per plant). Architect N1b: skipped instances don't block.
  exclude using gist (area_id with =, tstzrange(starts_at, ends_at) with &&) where (skipped_at is null)
);
alter table public.shift_instances enable row level security;
create index shift_instances_plant_org_idx on public.shift_instances (plant_id, org_id);
create index shift_instances_shift_plant_idx on public.shift_instances (shift_id, plant_id);
create index shift_instances_shift_area_idx on public.shift_instances (shift_id, area_id);
create index shift_instances_day_report_idx on public.shift_instances (plant_id, business_date, area_id);
create index shift_instances_area_starts_idx on public.shift_instances (area_id, starts_at);

-- ── Entry staff (A8: who entered data; attribution only, not per-worker output) ──
-- Deviations from §4.4 (D2): pin_hash is NULLABLE (null = PIN not set yet); has_pin is a generated,
-- client-selectable flag so admin screens can show "PIN not set" without touching pin_hash.
create table public.entry_staff (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  display_name  text not null check (char_length(display_name) between 1 and 60 and app.is_clean_text(display_name)),
  language      text not null default 'es' references public.languages(code),
  home_shift_id uuid,
  pin_hash      text,                                     -- bcrypt via extensions.crypt(); never selectable
  has_pin       boolean generated always as (pin_hash is not null) stored,
  failed_pin_attempts int not null default 0 check (failed_pin_attempts between 0 and 5),
  locked_until  timestamptz,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (home_shift_id, plant_id) references public.shifts(id, plant_id),
  unique (id, plant_id),
  unique (plant_id, display_name)
);
alter table public.entry_staff enable row level security;
create index entry_staff_plant_org_idx on public.entry_staff (plant_id, org_id);
create index entry_staff_home_shift_plant_idx on public.entry_staff (home_shift_id, plant_id);
create index entry_staff_language_idx on public.entry_staff (language);

-- D2: secrets are never selectable, insertable or updatable by clients. Column-level grants only.
revoke all on public.entry_staff from anon, authenticated;
grant select (id, org_id, plant_id, display_name, language, home_shift_id, has_pin, active, created_at, updated_at)
  on public.entry_staff to authenticated;
grant insert (org_id, plant_id, display_name, language, home_shift_id, active)
  on public.entry_staff to authenticated;
grant update (display_name, language, home_shift_id, active)
  on public.entry_staff to authenticated;

-- §4.7 lead R goes through this view (security_invoker: entry_staff RLS + column grants apply).
create view public.entry_staff_public with (security_invoker = true) as
  select id, org_id, plant_id, display_name, language, home_shift_id, has_pin, active, created_at, updated_at
    from public.entry_staff;
revoke all on public.entry_staff_public from anon, authenticated;
grant select on public.entry_staff_public to authenticated;
comment on view public.entry_staff_public is 'A8/D2: entry staff without secrets (pin_hash, failed_pin_attempts, locked_until).';

-- D3: staff_sessions adds org_id + composite plant FK and consumed_at. RLS on, NO policies (RPC-only).
create table public.staff_sessions (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  staff_id      uuid not null,
  auth_user_id  uuid not null references auth.users(id),
  confirmed_at  timestamptz not null default now(),
  expires_at    timestamptz not null,                     -- confirmed_at + reuse window (+ 2 min for 0)
  consumed_at   timestamptz,                              -- single-use sessions (reuse = 0), set by write RPCs (M2)
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (staff_id, plant_id) references public.entry_staff(id, plant_id),
  check (expires_at > confirmed_at)
);
alter table public.staff_sessions enable row level security;
revoke all on public.staff_sessions from anon, authenticated;
create index staff_sessions_plant_org_idx on public.staff_sessions (plant_id, org_id);
create index staff_sessions_staff_plant_idx on public.staff_sessions (staff_id, plant_id);
create index staff_sessions_auth_user_idx on public.staff_sessions (auth_user_id);

-- ── Triggers ──────────────────────────────────────────────────────────────
-- Architect N1a: active shifts of one area must not overlap anywhere in the week, so generation
-- can never hit the exclusion constraint. Week minutes: day*1440 + start; crossing midnight adds
-- 1440; ranges compare modulo the 10080-minute week (Saturday night wraps into Sunday).
-- SECURITY INVOKER: callers only see shifts their RLS allows (no cross-tenant oracle);
-- service role / postgres see all.
create function app.check_shift_overlap()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not new.active then
    return new;
  end if;
  if exists (
    with mine as (
      select d * 1440 + extract(epoch from new.start_local)::int / 60 as s,
             d * 1440 + extract(epoch from new.start_local)::int / 60
               + case when new.end_local <= new.start_local then 1440 else 0 end
               + (extract(epoch from new.end_local)::int - extract(epoch from new.start_local)::int) / 60 as e
        from unnest(new.days_of_week) d
    ), theirs as (
      select d * 1440 + extract(epoch from o.start_local)::int / 60 as s,
             d * 1440 + extract(epoch from o.start_local)::int / 60
               + case when o.end_local <= o.start_local then 1440 else 0 end
               + (extract(epoch from o.end_local)::int - extract(epoch from o.start_local)::int) / 60 as e
        from public.shifts o
       cross join lateral unnest(o.days_of_week) d
       where o.area_id = new.area_id and o.active and o.id <> new.id
    )
    select 1 from mine m cross join theirs t cross join (values (-10080), (0), (10080)) k(off)
     where m.s < t.e + k.off and t.s + k.off < m.e) then
    raise exception 'VALIDATION_FAILED' using detail = 'shift: overlaps another active shift of the same area';
  end if;
  return new;
end;
$$;
comment on function app.check_shift_overlap() is
  'A6/N1a BEFORE INSERT/UPDATE on shifts: rejects (VALIDATION_FAILED) an active shift whose weekly hours overlap another active shift in the same area.';

create trigger shifts_check_overlap
  before insert or update of area_id, start_local, end_local, days_of_week, active on public.shifts
  for each row execute function app.check_shift_overlap();
create trigger shifts_audit after insert or update on public.shifts
  for each row execute function app.audit();
create trigger shift_instances_audit after update on public.shift_instances
  for each row execute function app.audit();
create trigger entry_staff_touch_updated_at before update on public.entry_staff
  for each row execute function app.touch_updated_at();
create trigger entry_staff_check_languages before insert or update of language, plant_id on public.entry_staff
  for each row execute function app.check_languages();
create trigger entry_staff_audit after insert or update on public.entry_staff
  for each row execute function app.audit();

-- ── Shift helpers ─────────────────────────────────────────────────────────
-- A6: clock-based lookup. The area's non-skipped instance containing p_ts, or null (off-shift).
create function app.shift_instance_at(p_area_id uuid, p_ts timestamptz)
returns uuid language sql stable security definer set search_path = '' as $$
  select si.id
    from public.shift_instances si
   where si.area_id = p_area_id
     and si.skipped_at is null
     and si.starts_at <= p_ts
     and si.ends_at > p_ts
   order by si.starts_at desc
   limit 1;
$$;
comment on function app.shift_instance_at(uuid, timestamptz) is
  'A6: id of the area''s non-skipped shift instance whose [starts_at, ends_at) contains p_ts; null = off-shift.';
grant execute on function app.shift_instance_at(uuid, timestamptz) to service_role;

-- D6: generate instances for p_days days from p_from (null = plant-local today). DST-safe:
-- starts_at = (business_date + start_local) AT TIME ZONE plant tz. Idempotent: re-running updates the
-- times only of FUTURE instances that no row references. Run by pg_cron / service role only.
-- The production tables in the NOT EXISTS checks are created by later migrations; plpgsql
-- resolves them at call time.
create function app.generate_shift_instances(p_plant_id uuid, p_days int, p_from date default null)
returns int language plpgsql volatile security definer set search_path = '' as $$
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
       and (not s.active or not (extract(dow from si.business_date)::smallint = any (s.days_of_week)))
       and not exists (select 1 from public.finished_goods_entries f where f.shift_instance_id = si.id)
       and not exists (select 1 from public.washer_cycles w where w.shift_instance_id = si.id)
       and not exists (select 1 from public.shift_crew_hours h where h.shift_instance_id = si.id)
       and not exists (select 1 from public.alert_events a where a.shift_instance_id = si.id)
    returning 1
  )
  select v_count + count(*)::int into v_count from retired;
  return v_count;
end;
$$;
comment on function app.generate_shift_instances(uuid, int, date) is
  'A6/D6: creates shift_instances for p_days (1–60) days from p_from (default plant-local today), per active shift and day of week (0=Sun). DST-safe via AT TIME ZONE. Idempotent; updates times only of unreferenced future instances, and marks unreferenced future instances of inactive shifts / removed weekdays as skipped (N1c). Returns rows inserted, updated or skipped. service_role/postgres only.';
revoke all on function app.generate_shift_instances(uuid, int, date) from public;
grant execute on function app.generate_shift_instances(uuid, int, date) to service_role;

-- Architect N1d: the pg_cron entry point. One plant failing never blocks the others; a failure is
-- recorded in alert_events (kind shift_generation_failed, subject = plant) for the alert mailer.
-- alert_events is created in create_messaging_and_alerts; plpgsql resolves it at call time.
create function app.generate_all_shift_instances(p_days int default 7, p_from date default null)
returns int language plpgsql volatile security definer set search_path = '' as $$
declare
  v_plant record;
  v_total int := 0;
begin
  for v_plant in select p.id, p.org_id from public.plants p order by p.id loop
    begin
      v_total := v_total + app.generate_shift_instances(v_plant.id, p_days, p_from);
    exception when others then
      raise warning 'generate_shift_instances failed for plant %: % (%)', v_plant.id, sqlerrm, sqlstate;
      insert into public.alert_events (org_id, plant_id, kind, subject_id, recipients)
      values (v_plant.org_id, v_plant.id, 'shift_generation_failed', v_plant.id, '{}')
      on conflict (kind, subject_id, shift_instance_id) do update set sent_at = excluded.sent_at, recipients = '{}';
    end;
  end loop;
  return v_total;
end;
$$;
comment on function app.generate_all_shift_instances(int, date) is
  'A6/N1d pg_cron entry point (service_role/postgres only): runs app.generate_shift_instances for every plant; a failing plant is logged as alert_events kind shift_generation_failed (subject_id = plant; sent_at = latest failure, recipients reset) and the loop continues. Returns total rows changed.';
revoke all on function app.generate_all_shift_instances(int, date) from public;
grant execute on function app.generate_all_shift_instances(int, date) to service_role;

-- D5: person-based shift attribution (A8). Returns a shift_instance id, or null (off-shift).
create function app.resolve_entry_shift(p_staff_id uuid, p_choice text, p_ts timestamptz, p_area_id uuid)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare
  v_choice     text := coalesce(p_choice, 'own');
  v_area_plant uuid;
  v_staff      record;
  v_home       record;
  v_base_id    uuid;
  v_base_end   timestamptz;
begin
  if p_staff_id is null or p_ts is null or p_area_id is null or v_choice not in ('own', 'next') then
    raise exception 'VALIDATION_FAILED' using detail = 'resolve_entry_shift: staff, area and timestamp required; choice own|next';
  end if;
  select a.plant_id into v_area_plant from public.areas a where a.id = p_area_id;
  select s.plant_id, s.home_shift_id into v_staff from public.entry_staff s where s.id = p_staff_id;
  if not found or v_area_plant is null or v_staff.plant_id <> v_area_plant then
    raise exception 'VALIDATION_FAILED' using detail = 'staff_id/area_id: not found or not in the same plant';
  end if;

  -- Home shift = every ACTIVE shift with the home shift's (area_id, name), e.g. Thursday variants.
  if v_staff.home_shift_id is not null then
    select sh.area_id, sh.name into v_home from public.shifts sh where sh.id = v_staff.home_shift_id;
    if v_home.area_id = p_area_id then
      select si.id, si.ends_at into v_base_id, v_base_end
        from public.shift_instances si
        join public.shifts sh on sh.id = si.shift_id
       where sh.area_id = v_home.area_id
         and sh.name = v_home.name
         and sh.active
         and si.skipped_at is null
         and si.starts_at <= p_ts
         and si.ends_at >= p_ts - interval '6 hours'
       order by (si.ends_at > p_ts) desc, si.ends_at desc   -- containing p_ts first, else most recent
       limit 1;
    end if;
  end if;

  -- Fallback: clock-based instance of the area (skipped excluded).
  if v_base_id is null then
    v_base_id := app.shift_instance_at(p_area_id, p_ts);
    if v_base_id is null then
      return null;  -- off-shift
    end if;
    select si.ends_at into v_base_end from public.shift_instances si where si.id = v_base_id;
  end if;

  if v_choice = 'own' then
    return v_base_id;
  end if;
  -- 'next' = next non-skipped instance in the same area starting at/after the chosen one's end.
  return (select si.id
            from public.shift_instances si
           where si.area_id = p_area_id
             and si.skipped_at is null
             and si.starts_at >= v_base_end
           order by si.starts_at
           limit 1);
end;
$$;
comment on function app.resolve_entry_shift(uuid, text, timestamptz, uuid) is
  'A8/D5: own = the non-skipped instance of the staff''s home shift (same area+name, active) containing p_ts, else the latest that ended ≤ 6 h before; fallback app.shift_instance_at(area, ts). next = the area''s next non-skipped instance starting at/after the chosen one''s end. Null = off-shift.';
grant execute on function app.resolve_entry_shift(uuid, text, timestamptz, uuid) to service_role;

-- ── RPCs (§5.3) ───────────────────────────────────────────────────────────
-- set_staff_pin: owner/manager. 4 digits; not 0000, 1234 or one repeated digit; unique among the
-- plant's other ACTIVE staff (compared with crypt); bcrypt; resets the lockout counters.
create function public.set_staff_pin(p_staff_id uuid, p_pin text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare
  v_plant uuid;
begin
  select s.plant_id into v_plant from public.entry_staff s where s.id = p_staff_id;
  if v_plant is null or not app.has_role(v_plant, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'set_staff_pin requires owner or manager on the staff''s plant';
  end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception 'VALIDATION_FAILED' using detail = 'pin: exactly 4 digits';
  end if;
  if p_pin = '1234' or p_pin ~ '^(.)\1{3}$' then
    raise exception 'VALIDATION_FAILED' using detail = 'pin: too easy to guess (0000, 1234 or one repeated digit)';
  end if;

  -- Serialize PIN changes per plant so the uniqueness check cannot race.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('set_staff_pin:' || v_plant::text, 0));
  if exists (select 1 from public.entry_staff o
              where o.plant_id = v_plant
                and o.id <> p_staff_id
                and o.active
                and o.pin_hash is not null
                and o.pin_hash = extensions.crypt(p_pin, o.pin_hash)) then
    raise exception 'VALIDATION_FAILED' using detail = 'pin: already used by another active person in this plant';
  end if;

  update public.entry_staff
     set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf')),
         failed_pin_attempts = 0,
         locked_until = null
   where id = p_staff_id;
end;
$$;
comment on function public.set_staff_pin(uuid, text) is
  'A8 RPC (owner/manager): set or reset a staff member''s 4-digit PIN (bcrypt). Rejects weak PINs and PINs already used by another active person in the plant. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.set_staff_pin(uuid, text) from public, anon;
grant execute on function public.set_staff_pin(uuid, text) to authenticated, service_role;

-- D4 start_staff_session: owner/manager/lead. Wrong PIN RETURNS 'PIN_INVALID' (no raise, so the
-- failed-attempt counter commits); the 5th failure locks for 5 min and resets the counter.
-- D4 typed return (not jsonb): a named composite so generated TS types carry the fields.
create type public.staff_session_result as (staff_session_id uuid, error text, locked_until timestamptz);
comment on type public.staff_session_result is 'start_staff_session result: session id, or error PIN_INVALID / STAFF_LOCKED (+ locked_until).';

create function public.start_staff_session(p_staff_id uuid, p_pin text)
returns public.staff_session_result language plpgsql volatile security definer set search_path = '' as $$
declare
  v_staff   record;
  v_reuse   int;
  v_now     timestamptz := pg_catalog.now();
  v_result  public.staff_session_result;
begin
  if p_staff_id is null or p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception 'VALIDATION_FAILED' using detail = 'p_staff_id required; p_pin exactly 4 digits';
  end if;
  select s.id, s.org_id, s.plant_id, s.active, s.pin_hash, s.failed_pin_attempts, s.locked_until
    into v_staff
    from public.entry_staff s
   where s.id = p_staff_id
     for update;
  if not found or (select auth.uid()) is null
     or not app.has_role(v_staff.plant_id, '{owner,manager,lead}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'start_staff_session requires owner, manager or lead on the staff''s plant';
  end if;
  if not v_staff.active then
    raise exception 'VALIDATION_FAILED' using detail = 'staff: inactive';
  end if;
  if v_staff.pin_hash is null then
    raise exception 'VALIDATION_FAILED' using detail = 'staff: PIN not set';
  end if;

  if v_staff.locked_until is not null and v_staff.locked_until > v_now then
    v_result.error := 'STAFF_LOCKED';
    v_result.locked_until := v_staff.locked_until;
    return v_result;
  end if;

  if extensions.crypt(p_pin, v_staff.pin_hash) = v_staff.pin_hash then
    update public.entry_staff s
       set failed_pin_attempts = 0, locked_until = null
     where s.id = p_staff_id;
    select p.staff_pin_reuse_minutes into v_reuse from public.plants p where p.id = v_staff.plant_id;
    insert into public.staff_sessions as ss (org_id, plant_id, staff_id, auth_user_id, confirmed_at, expires_at)
    values (v_staff.org_id, v_staff.plant_id, p_staff_id, (select auth.uid()), v_now,
            v_now + case when v_reuse = 0 then interval '2 minutes'
                         else pg_catalog.make_interval(mins => v_reuse) end)
    returning ss.id into v_result.staff_session_id;
    return v_result;
  end if;

  -- Wrong PIN: count it; the 5th consecutive failure locks the person for 5 minutes.
  if v_staff.failed_pin_attempts + 1 >= 5 then
    update public.entry_staff s
       set failed_pin_attempts = 0, locked_until = v_now + interval '5 minutes'
     where s.id = p_staff_id;
    v_result.error := 'STAFF_LOCKED';
    v_result.locked_until := v_now + interval '5 minutes';
  else
    update public.entry_staff s
       set failed_pin_attempts = s.failed_pin_attempts + 1
     where s.id = p_staff_id;
    v_result.error := 'PIN_INVALID';
  end if;
  return v_result;
end;
$$;
comment on function public.start_staff_session(uuid, text) is
  'A8/D4 RPC (owner/manager/lead): confirm name + PIN. Returns (staff_session_id, error, locked_until): success → session valid staff_pin_reuse_minutes (2 min when 0); wrong PIN → error PIN_INVALID (counter persists); 5th failure or locked → STAFF_LOCKED + locked_until. Raises NOT_AUTHORIZED / VALIDATION_FAILED for bad caller, inactive staff, PIN not set or bad arguments.';
revoke all on function public.start_staff_session(uuid, text) from public, anon;
grant execute on function public.start_staff_session(uuid, text) to authenticated, service_role;

-- set_shift_skipped (P1): owner/manager mark a generated instance "didn't run". Audited by trigger.
create function public.set_shift_skipped(p_shift_instance_id uuid, p_skipped boolean)
returns public.shift_instances language plpgsql volatile security definer set search_path = '' as $$
declare
  v_plant uuid;
  v_row   public.shift_instances;
begin
  select si.plant_id into v_plant from public.shift_instances si where si.id = p_shift_instance_id;
  if v_plant is null or not app.has_role(v_plant, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'set_shift_skipped requires owner or manager on the plant';
  end if;
  if p_skipped is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_skipped: required';
  end if;
  update public.shift_instances si
     set skipped_at = case when p_skipped then coalesce(si.skipped_at, pg_catalog.now()) else null end
   where si.id = p_shift_instance_id
  returning si.* into v_row;
  return v_row;
end;
$$;
comment on function public.set_shift_skipped(uuid, boolean) is
  'A6 (P1) RPC (owner/manager): set (p_skipped=true) or clear skipped_at on a shift instance; skipped instances are ignored by shift lookups and hidden from reports. Audited. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.set_shift_skipped(uuid, boolean) from public, anon;
grant execute on function public.set_shift_skipped(uuid, boolean) to authenticated, service_role;

-- ── RLS policies (§4.7) ───────────────────────────────────────────────────
create policy shifts_select on public.shifts for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')) or (select app.is_display(plant_id)));
create policy shifts_insert on public.shifts for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager}')));
create policy shifts_update on public.shifts for update to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')))
  with check ((select app.has_role(plant_id, '{owner,manager}')));

-- shift_instances: R for all; writes only via generate_shift_instances / set_shift_skipped.
create policy shift_instances_select on public.shift_instances for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')) or (select app.is_display(plant_id)));

-- entry_staff: owner/manager R C U, lead R (non-secret columns only, D2); viewer/display none.
create policy entry_staff_select on public.entry_staff for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead}')));
create policy entry_staff_insert on public.entry_staff for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager}')));
create policy entry_staff_update on public.entry_staff for update to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')))
  with check ((select app.has_role(plant_id, '{owner,manager}')));
-- staff_sessions: no policies (RPC-only, D3).
