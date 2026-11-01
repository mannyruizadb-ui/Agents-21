-- M1 · tenancy, languages, audit (PRD §4.3 enums, §4.4 tenancy tables, §4.5, §4.7 helpers).
-- RLS is enabled in this same migration for every table it creates (deny-by-default).

-- Least privilege for functions. The Sprint Zero statement
--   alter default privileges in schema app revoke execute on functions from public;
-- is a no-op: per-schema default privileges can only ADD to the global defaults, and PUBLIC's
-- EXECUTE comes from the global default. Revoke it globally for functions created by postgres.
-- public-schema RPCs still get Supabase's per-schema grants (anon, authenticated, service_role),
-- and every RPC below revokes anon explicitly. app functions are granted per function.
alter default privileges for role postgres revoke execute on functions from public;

-- ── §4.3 enumerated types ─────────────────────────────────────────────────
create type app.member_role   as enum ('owner','manager','lead','viewer','display');
create type app.area_kind     as enum ('washroom','finishing','folding','packing','other');
create type app.station_kind  as enum ('ironer','folder','mat_roller','packing','washroom','other');
create type app.machine_kind  as enum ('washer','dryer','ironer','folder','other');
create type app.item_category as enum ('mat','linen','apparel','towel','mop','other');
create type app.qty_unit      as enum ('load','basket','piece','pack');   -- no weight units: ADB has no scale
create type app.count_mode    as enum ('unit','pack');
create type app.queue_status  as enum ('queued','in_progress','done','cancelled');
create type app.entry_source  as enum ('manual','queue_completion');
create type app.cycle_source  as enum ('manual','accuflow_csv','accuflow_api');
create type app.msg_severity  as enum ('info','urgent');

-- ── §4.9 text rule: trimmed, no control characters ────────────────────────
create function app.is_clean_text(p text)
returns boolean language sql immutable parallel safe set search_path = '' as $$
  select p is null or (p = pg_catalog.btrim(p) and p !~ '[[:cntrl:]]');
$$;
comment on function app.is_clean_text(text) is
  '§4.9 Text rule: null, or trimmed with no control characters. Used in CHECK constraints.';

-- §4.9 accessibility prefs: undo_seconds 10–60, text_scale 1.0–2.0, every other key boolean.
create function app.valid_a11y_prefs(p jsonb)
returns boolean language sql immutable parallel safe set search_path = '' as $$
  select pg_catalog.jsonb_typeof(p) = 'object'
     and not exists (
       select 1 from pg_catalog.jsonb_each(p) e(k, v)
        where case e.k
                when 'text_scale' then
                  pg_catalog.jsonb_typeof(e.v) <> 'number'
                  or (e.v #>> '{}')::numeric not between 1.0 and 2.0
                when 'undo_seconds' then
                  pg_catalog.jsonb_typeof(e.v) <> 'number'
                  or (e.v #>> '{}')::numeric not between 10 and 60
                  or (e.v #>> '{}')::numeric <> pg_catalog.trunc((e.v #>> '{}')::numeric)
                else pg_catalog.jsonb_typeof(e.v) <> 'boolean'
              end);
$$;
comment on function app.valid_a11y_prefs(jsonb) is
  '§4.9 a11y_prefs: undo_seconds integer 10–60, text_scale 1.0–2.0, any other key boolean.';

grant execute on function app.is_clean_text(text) to authenticated, service_role;
grant execute on function app.valid_a11y_prefs(jsonb) to authenticated, service_role;

-- ── Languages (global reference data; H1) ─────────────────────────────────
create table public.languages (
  code        text primary key check (code ~ '^[a-z]{2,3}(-[A-Z]{2})?$'),
  name_native text not null check (char_length(name_native) between 1 and 40),
  rtl         boolean not null default false,
  ui_ready    boolean not null default false,
  speech_recognition_tested boolean not null default false
);
alter table public.languages enable row level security;

-- ── Tenancy ───────────────────────────────────────────────────────────────
create table public.organizations (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 120 and app.is_clean_text(name)),
  slug        text not null unique check (slug ~ '^[a-z0-9-]{3,40}$'),
  created_at  timestamptz not null default now()
);
alter table public.organizations enable row level security;

create table public.plants (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id) on delete restrict,
  name        text not null check (char_length(name) between 1 and 120 and app.is_clean_text(name)),
  timezone    text not null default 'America/New_York',
  default_language  text not null default 'en' references public.languages(code),
  enabled_languages text[] not null default '{en,es}' check (cardinality(enabled_languages) >= 1),
  estimate_amber_minutes int not null default 120 check (estimate_amber_minutes > 0),
  estimate_red_minutes   int not null default 240 check (estimate_red_minutes > estimate_amber_minutes),
  display_reload_local_time time not null default '04:00',
  staff_pin_reuse_minutes int not null default 0 check (staff_pin_reuse_minutes between 0 and 480),
  created_at  timestamptz not null default now(),
  unique (id, org_id)
);
alter table public.plants enable row level security;
create index plants_org_id_idx on public.plants (org_id);
create index plants_default_language_idx on public.plants (default_language);

create table public.profiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  full_name   text check (char_length(full_name) <= 120 and app.is_clean_text(full_name)),
  language    text not null default 'en' references public.languages(code),
  a11y_prefs  jsonb not null default '{}'::jsonb check (app.valid_a11y_prefs(a11y_prefs)),
  notify_email boolean not null default true,
  created_at  timestamptz not null default now()
);
alter table public.profiles enable row level security;
create index profiles_language_idx on public.profiles (language);

create table public.memberships (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  org_id      uuid not null references public.organizations(id) on delete cascade,
  plant_id    uuid,                                     -- null = all plants in org
  role        app.member_role not null,
  created_at  timestamptz not null default now(),
  revoked_at  timestamptz,
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  unique nulls not distinct (user_id, org_id, plant_id)
);
alter table public.memberships enable row level security;
create index memberships_active_user_org_idx on public.memberships (user_id, org_id) where revoked_at is null;
create index memberships_org_id_idx on public.memberships (org_id);
create index memberships_plant_org_idx on public.memberships (plant_id, org_id);

-- ── Audit + analytics (H2, H5) ────────────────────────────────────────────
-- Deviation from §4.4: composite FK (plant_id, org_id) → plants added so a row's plant always
-- belongs to its org. actor_device_id's FK → devices is added in create_devices_and_pairing.
create table public.audit_log (
  id          bigint generated always as identity primary key,
  org_id      uuid not null references public.organizations(id),
  plant_id    uuid,
  actor_user_id uuid references auth.users(id),
  actor_device_id uuid,
  action      text not null,
  entity      text not null,
  entity_id   uuid,
  before      jsonb,
  after       jsonb,
  at          timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id)
);
alter table public.audit_log enable row level security;
create index audit_log_entity_idx on public.audit_log (org_id, entity, entity_id, at desc);
create index audit_log_plant_org_idx on public.audit_log (plant_id, org_id);
create index audit_log_actor_user_idx on public.audit_log (actor_user_id);
create index audit_log_actor_device_idx on public.audit_log (actor_device_id);

create table public.app_events (
  id          bigint generated always as identity primary key,
  org_id      uuid not null references public.organizations(id),
  plant_id    uuid,
  user_id     uuid,
  device_id   uuid,
  name        text not null check (char_length(name) between 1 and 60 and app.is_clean_text(name)),
  props       jsonb not null default '{}'::jsonb check (jsonb_typeof(props) = 'object'),
  at          timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id)
);
alter table public.app_events enable row level security;
create index app_events_org_name_at_idx on public.app_events (org_id, name, at);
create index app_events_plant_org_idx on public.app_events (plant_id, org_id);
create index app_events_device_idx on public.app_events (device_id);

-- ── §4.7 RLS helpers ──────────────────────────────────────────────────────
-- true if the current user has any of the roles on the plant (direct or org-wide membership).
create function app.has_role(p_plant uuid, p_roles app.member_role[])
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    join public.plants p on p.id = p_plant
    where m.user_id = (select auth.uid())
      and m.revoked_at is null
      and m.org_id = p.org_id
      and (m.plant_id is null or m.plant_id = p_plant)
      and m.role = any (p_roles));
$$;
comment on function app.has_role(uuid, app.member_role[]) is
  '§4.7 RLS helper: caller has one of p_roles on the plant (plant or org-wide membership, not revoked).';

-- true if the current user has an ORG-WIDE membership (plant_id null) with one of the roles.
-- Used for org-level rows (plant_id null) in audit_log / app_events and for organizations.
create function app.has_org_role(p_org uuid, p_roles app.member_role[])
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    where m.user_id = (select auth.uid())
      and m.revoked_at is null
      and m.org_id = p_org
      and m.plant_id is null
      and m.role = any (p_roles));
$$;
comment on function app.has_org_role(uuid, app.member_role[]) is
  '§4.7 RLS helper: caller has an org-wide (plant_id null) membership in p_org with one of p_roles.';

-- D13: a display reads only with a display membership AND a live (non-revoked) device row in the
-- same plant. plpgsql resolves app.my_device()/public.devices at call time; both are created in
-- migration create_devices_and_pairing, before any row can exist.
create function app.is_display(p_plant uuid)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
  return app.has_role(p_plant, array['display']::app.member_role[])
     and exists (select 1 from app.my_device() d where d.id is not null and d.plant_id = p_plant);
end;
$$;
comment on function app.is_display(uuid) is
  'D13 RLS helper: caller is a paired, non-revoked display device of the plant (display membership + devices row).';

grant execute on function app.has_role(uuid, app.member_role[]) to authenticated, service_role;
grant execute on function app.has_org_role(uuid, app.member_role[]) to authenticated, service_role;
grant execute on function app.is_display(uuid) to authenticated, service_role;

-- ── §4.5 generic triggers ─────────────────────────────────────────────────
create function app.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
comment on function app.touch_updated_at() is '§4.5 BEFORE UPDATE: sets updated_at = now().';

-- §4.9: plant timezone must exist in pg_timezone_names.
create function app.check_timezone()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.timezone) then
    raise exception 'VALIDATION_FAILED' using detail = 'timezone: not in pg_timezone_names';
  end if;
  return new;
end;
$$;
comment on function app.check_timezone() is '§4.9 BEFORE INSERT/UPDATE on plants: timezone must exist in pg_timezone_names.';

-- §4.5 app.check_languages(): one generic function, attached per table. Rules (§4.9, H1):
-- codes exist in languages; user/display/translation languages are enabled for the plant;
-- translation values are strings of 1–60 chars (140 for display_messages).
create function app.check_languages()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_enabled text[];
  v_code    text;
  v_val     jsonb;
  v_max     int := 60;
  v_map     jsonb;
begin
  if tg_table_name = 'plants' then
    if exists (select 1 from unnest(new.enabled_languages) c
                where not exists (select 1 from public.languages l where l.code = c)) then
      raise exception 'VALIDATION_FAILED' using detail = 'enabled_languages: unknown language code';
    end if;
    if not (new.default_language = any (new.enabled_languages)) then
      raise exception 'VALIDATION_FAILED' using detail = 'default_language: must be in enabled_languages';
    end if;
    return new;
  end if;

  if tg_table_name = 'profiles' then
    -- A user's language must be enabled in at least one plant they belong to (if any yet).
    select coalesce(array_agg(distinct l), '{}') into v_enabled
      from public.memberships m
      join public.plants p on p.org_id = m.org_id and (m.plant_id is null or m.plant_id = p.id)
      cross join lateral unnest(p.enabled_languages) l
     where m.user_id = new.user_id and m.revoked_at is null;
    if cardinality(v_enabled) > 0 and not (new.language = any (v_enabled)) then
      raise exception 'VALIDATION_FAILED' using detail = 'language: not enabled for any of the user''s plants';
    end if;
    return new;
  end if;

  -- Plant-scoped tables: devices, item_types, display_messages, entry_staff.
  select p.enabled_languages into v_enabled from public.plants p where p.id = new.plant_id;
  if v_enabled is null then
    return new;  -- the plant FK reports the missing plant
  end if;

  if tg_table_name = 'devices' then
    if exists (select 1 from unnest(new.display_languages) c where not (c = any (v_enabled))) then
      raise exception 'VALIDATION_FAILED' using detail = 'display_languages: not enabled for the plant';
    end if;
    return new;
  elsif tg_table_name = 'entry_staff' then
    if not (new.language = any (v_enabled)) then
      raise exception 'VALIDATION_FAILED' using detail = 'language: not enabled for the plant';
    end if;
    return new;
  elsif tg_table_name = 'item_types' then
    v_map := new.name_i18n;
  elsif tg_table_name = 'display_messages' then
    if not (new.body_lang = any (v_enabled)) then
      raise exception 'VALIDATION_FAILED' using detail = 'body_lang: not enabled for the plant';
    end if;
    v_map := new.body_i18n;
    v_max := 140;
  else
    raise exception 'app.check_languages() is not configured for table %', tg_table_name;
  end if;

  for v_code, v_val in select key, value from jsonb_each(v_map) loop
    if not (v_code = any (v_enabled)) then
      raise exception 'VALIDATION_FAILED' using detail = format('i18n: language %s not enabled for the plant', v_code);
    end if;
    if jsonb_typeof(v_val) <> 'string'
       or char_length(v_val #>> '{}') not between 1 and v_max
       or not app.is_clean_text(v_val #>> '{}') then
      raise exception 'VALIDATION_FAILED' using detail = format('i18n: value for %s must be 1–%s clean characters', v_code, v_max);
    end if;
  end loop;
  return new;
end;
$$;
comment on function app.check_languages() is
  '§4.5 BEFORE INSERT/UPDATE on plants, profiles, devices, item_types, display_messages, entry_staff: language codes exist and are enabled for the plant; i18n values 1–60 (140 for messages) chars.';

-- §4.5 / H2 app.audit(): AFTER INSERT/UPDATE, writes before/after JSON to audit_log.
-- D12: never writes pin_hash; skips entry_staff updates that only touch the lockout counters.
-- No INSERT policy exists on audit_log: only this SECURITY DEFINER function writes it.
create function app.audit()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_before jsonb;
  v_after  jsonb;
  v_org    uuid;
  v_plant  uuid;
  v_action text := tg_table_name || '.' || lower(tg_op);
  v_device uuid;
begin
  -- Columns are read through jsonb so this one function works on tables without them.
  v_after := to_jsonb(new) - 'pin_hash';
  if tg_op = 'UPDATE' then
    v_before := to_jsonb(old) - 'pin_hash';
    if tg_table_name = 'entry_staff'
       and (to_jsonb(old) ->> 'pin_hash') is distinct from (to_jsonb(new) ->> 'pin_hash') then
      v_action := 'entry_staff.pin_set';
    elsif v_before = v_after then
      return null;  -- no-op update
    elsif tg_table_name = 'entry_staff'
          and (v_before - 'failed_pin_attempts' - 'locked_until' - 'updated_at')
            = (v_after  - 'failed_pin_attempts' - 'locked_until' - 'updated_at') then
      return null;  -- D12: lockout-counter-only update
    end if;
    if tg_table_name = 'finished_goods_entries'
       and v_before ->> 'voided_at' is null and v_after ->> 'voided_at' is not null then
      v_action := 'finished_goods_entries.void';
    end if;
  end if;

  if tg_table_name = 'organizations' then
    v_org := new.id;
  else
    v_org := (v_after ->> 'org_id')::uuid;
  end if;
  if tg_table_name = 'plants' then
    v_plant := new.id;
  else
    v_plant := (v_after ->> 'plant_id')::uuid;
  end if;

  -- devices exists from migration create_devices_and_pairing on (plpgsql resolves at call time).
  select d.id into v_device from public.devices d
   where d.user_id = (select auth.uid()) and d.revoked_at is null;

  insert into public.audit_log (org_id, plant_id, actor_user_id, actor_device_id, action, entity, entity_id, before, after)
  values (v_org, v_plant, (select auth.uid()), v_device, v_action, tg_table_name,
          (v_after ->> 'id')::uuid, v_before, v_after);
  return null;
end;
$$;
comment on function app.audit() is
  '§4.5/H2 AFTER INSERT/UPDATE: writes audit_log with before/after (pin_hash stripped, lockout-only updates skipped, D12).';

-- ── Triggers on this migration''s tables ───────────────────────────────────
create trigger plants_check_timezone before insert or update of timezone on public.plants
  for each row execute function app.check_timezone();
create trigger plants_check_languages before insert or update of enabled_languages, default_language on public.plants
  for each row execute function app.check_languages();
create trigger profiles_check_languages before insert or update of language on public.profiles
  for each row execute function app.check_languages();
create trigger organizations_audit after insert or update on public.organizations
  for each row execute function app.audit();
create trigger plants_audit after insert or update on public.plants
  for each row execute function app.audit();
create trigger memberships_audit after insert or update on public.memberships
  for each row execute function app.audit();

-- ── RLS policies (§4.7) ───────────────────────────────────────────────────
-- languages: global, readable by every signed-in user.
create policy languages_select on public.languages for select to authenticated using (true);

-- organizations: R for members (via a readable plant, or an org-wide membership); U owner.
create policy organizations_select on public.organizations for select to authenticated
  using ((select app.has_org_role(id, '{owner,manager,lead,viewer}'))
         or exists (select 1 from public.plants p where p.org_id = organizations.id));
create policy organizations_update on public.organizations for update to authenticated
  using ((select app.has_org_role(id, '{owner}')))
  with check ((select app.has_org_role(id, '{owner}')));

-- plants: R all roles (display: own plant, D13); U owner.
create policy plants_select on public.plants for select to authenticated
  using ((select app.has_role(id, '{owner,manager,lead,viewer}')) or (select app.is_display(id)));
create policy plants_update on public.plants for update to authenticated
  using ((select app.has_role(id, '{owner}')))
  with check ((select app.has_role(id, '{owner}')));

-- profiles: own row R U (no client insert; invite-user creates it).
create policy profiles_select_own on public.profiles for select to authenticated
  using (user_id = (select auth.uid()));
create policy profiles_update_own on public.profiles for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- memberships: owner R C U; manager R.
create policy memberships_select on public.memberships for select to authenticated
  using ((select app.has_org_role(org_id, '{owner,manager}'))
         or (plant_id is not null and (select app.has_role(plant_id, '{owner,manager}'))));
create policy memberships_insert on public.memberships for insert to authenticated
  with check ((select app.has_org_role(org_id, '{owner}'))
              or (plant_id is not null and (select app.has_role(plant_id, '{owner}'))));
create policy memberships_update on public.memberships for update to authenticated
  using ((select app.has_org_role(org_id, '{owner}'))
         or (plant_id is not null and (select app.has_role(plant_id, '{owner}'))))
  with check ((select app.has_org_role(org_id, '{owner}'))
              or (plant_id is not null and (select app.has_role(plant_id, '{owner}'))));

-- audit_log: owner/manager R. No INSERT/UPDATE policy: app.audit() writes it.
create policy audit_log_select on public.audit_log for select to authenticated
  using (case when plant_id is null then (select app.has_org_role(org_id, '{owner,manager}'))
              else (select app.has_role(plant_id, '{owner,manager}')) end);

-- app_events: owner/manager R; any plant member (incl. a paired display) C own events.
create policy app_events_select on public.app_events for select to authenticated
  using (case when plant_id is null then (select app.has_org_role(org_id, '{owner,manager}'))
              else (select app.has_role(plant_id, '{owner,manager}')) end);
create policy app_events_insert on public.app_events for insert to authenticated
  with check (user_id = (select auth.uid())
              and plant_id is not null
              and ((select app.has_role(plant_id, '{owner,manager,lead,viewer}'))
                   or (select app.is_display(plant_id))));
