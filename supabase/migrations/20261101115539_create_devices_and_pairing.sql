-- M1 · wall-display devices + pairing codes (PRD A7; §4.4 devices, pairing_codes; §4.7; §5.3).
-- pair-device / revoke-device Edge Functions (service role) arrive in M1 part 2.

create table public.devices (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  user_id       uuid not null unique references auth.users(id) on delete cascade,
  area_id       uuid not null,
  name          text not null check (char_length(name) between 1 and 60 and app.is_clean_text(name)),
  display_languages text[] not null default '{es,en}' check (cardinality(display_languages) between 1 and 2),
  app_version   text check (char_length(app_version) <= 40),
  last_seen_at  timestamptz,
  paired_at     timestamptz not null default now(),
  revoked_at    timestamptz,
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (area_id, plant_id) references public.areas(id, plant_id)
);
alter table public.devices enable row level security;
create index devices_plant_org_idx on public.devices (plant_id, org_id);
create index devices_area_plant_idx on public.devices (area_id, plant_id);

create table public.pairing_codes (
  code          text primary key check (code ~ '^[A-HJ-NP-Z2-9]{6}$'),   -- no 0/O/1/I
  org_id        uuid not null,
  plant_id      uuid not null,
  area_id       uuid not null,
  device_name   text not null check (char_length(device_name) between 1 and 60 and app.is_clean_text(device_name)),
  created_by    uuid not null references auth.users(id),
  expires_at    timestamptz not null,
  consumed_at   timestamptz,
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (area_id, plant_id) references public.areas(id, plant_id)
);
alter table public.pairing_codes enable row level security;
create index pairing_codes_plant_org_idx on public.pairing_codes (plant_id, org_id);
create index pairing_codes_area_plant_idx on public.pairing_codes (area_id, plant_id);
create index pairing_codes_created_by_idx on public.pairing_codes (created_by);

-- §4.4 audit_log.actor_device_id → devices (devices did not exist in the tenancy migration).
alter table public.audit_log
  add constraint audit_log_actor_device_id_fkey foreign key (actor_device_id) references public.devices(id);
-- Deviation from §4.4: app_events.device_id also references devices (DDL left it unconstrained).
alter table public.app_events
  add constraint app_events_device_id_fkey foreign key (device_id) references public.devices(id);

-- ── Triggers ──────────────────────────────────────────────────────────────
create trigger devices_check_languages before insert or update of display_languages, plant_id on public.devices
  for each row execute function app.check_languages();
create trigger devices_audit after insert or update on public.devices
  for each row execute function app.audit();

-- ── §4.7 helper ───────────────────────────────────────────────────────────
create function app.my_device()
returns public.devices language sql stable security definer set search_path = '' as $$
  select d.* from public.devices d
   where d.user_id = (select auth.uid()) and d.revoked_at is null;
$$;
comment on function app.my_device() is
  '§4.7 RLS helper: the caller''s non-revoked devices row (a null row when the caller is not a paired display).';
grant execute on function app.my_device() to authenticated, service_role;

-- ── RPC (§5.3) ────────────────────────────────────────────────────────────
-- create_pairing_code: owner/manager. 6 chars from the unambiguous alphabet (32 symbols, so
-- byte % 32 is unbiased), expires in 15 min, retries on collision.
create type public.pairing_code_result as (code text, expires_at timestamptz);
comment on type public.pairing_code_result is 'create_pairing_code result: the 6-character code and its expiry.';

create function public.create_pairing_code(p_area_id uuid, p_device_name text)
returns public.pairing_code_result language plpgsql volatile security definer set search_path = '' as $$
declare
  c_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_area     record;
  v_bytes    bytea;
  v_code     text;
  v_expires  timestamptz := pg_catalog.now() + interval '15 minutes';
begin
  select a.org_id, a.plant_id, a.active into v_area from public.areas a where a.id = p_area_id;
  if not found or not app.has_role(v_area.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'create_pairing_code requires owner or manager on the area''s plant';
  end if;
  if not v_area.active then
    raise exception 'VALIDATION_FAILED' using detail = 'p_area_id: area is inactive';
  end if;
  if p_device_name is null or char_length(p_device_name) not between 1 and 60
     or not app.is_clean_text(p_device_name) then
    raise exception 'VALIDATION_FAILED' using detail = 'p_device_name: 1–60 characters, trimmed, no control characters';
  end if;

  for attempt in 1..10 loop
    v_bytes := extensions.gen_random_bytes(6);
    v_code := '';
    for i in 0..5 loop
      v_code := v_code || substr(c_alphabet, (get_byte(v_bytes, i) % 32) + 1, 1);
    end loop;
    begin
      insert into public.pairing_codes as pc (code, org_id, plant_id, area_id, device_name, created_by, expires_at)
      values (v_code, v_area.org_id, v_area.plant_id, p_area_id, p_device_name, (select auth.uid()), v_expires);
      return row(v_code, v_expires)::public.pairing_code_result;
    exception when unique_violation then
      null;  -- collision: try another code
    end;
  end loop;
  raise exception 'RATE_LIMITED' using detail = 'could not allocate a unique pairing code; retry';
end;
$$;
comment on function public.create_pairing_code(uuid, text) is
  'A7 RPC (owner/manager): creates a single-use 6-character pairing code (alphabet without 0/O/1/I) for a display in p_area_id, valid 15 minutes. Returns (code, expires_at). Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.create_pairing_code(uuid, text) from public, anon;
grant execute on function public.create_pairing_code(uuid, text) to authenticated, service_role;

-- ── RLS policies (§4.7: devices, pairing_codes → owner/manager R C U; lead R; display own row R) ──
create policy devices_select on public.devices for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead}')) or user_id = (select auth.uid()));
create policy devices_insert on public.devices for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager}')));
create policy devices_update on public.devices for update to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')))
  with check ((select app.has_role(plant_id, '{owner,manager}')));

create policy pairing_codes_select on public.pairing_codes for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead}')));
create policy pairing_codes_insert on public.pairing_codes for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager}')) and created_by = (select auth.uid()));
create policy pairing_codes_update on public.pairing_codes for update to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')))
  with check ((select app.has_role(plant_id, '{owner,manager}')));
