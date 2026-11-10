-- Shared plant iPad (owner 2026-11-10): on ONE device the owner marks as the plant's shared iPad, the
-- sign-in screen lists the plant's managers and leads by name; a person taps their name and types their
-- own 6-digit password. Everywhere else the normal username sign-in stays.
--
-- Security model:
--   * The owner, signed in on the iPad, calls register_shared_device. It returns a random 256-bit token
--     ONCE; only its SHA-256 is stored. The token stays on that device (it is the device's proof).
--   * The name list and the name sign-in exist only in the sign-in Edge Function (service role). They
--     need a live token: anyone else on the public site sees no names.
--   * The password check is the normal one (lockout per login, pepper), keyed by the same login, so a
--     lock from the iPad and a lock from a phone are the same lock.
--   * Owners are never on the list (owner decision: an owner's 6 digits typed on the floor must not
--     give anyone owner rights). Viewers and display accounts are not listed either.
--   * The owner can revoke a device at any time; a revoked token lists nobody and signs in nobody.

create table public.shared_devices (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null,
  plant_id     uuid not null,
  label        text not null check (char_length(label) between 1 and 40 and app.is_clean_text(label)),
  token_hash   text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  created_by   uuid not null references auth.users(id),
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at   timestamptz,
  revoked_by   uuid references auth.users(id),
  foreign key (plant_id, org_id) references public.plants(id, org_id)
);
alter table public.shared_devices enable row level security;
create index shared_devices_plant_org_idx on public.shared_devices (plant_id, org_id);
create index shared_devices_created_by_idx on public.shared_devices (created_by);
create index shared_devices_revoked_by_idx on public.shared_devices (revoked_by);
comment on table public.shared_devices is
  'Shared plant iPads (owner 2026-11-10). token_hash = SHA-256 (hex) of the device token; the token itself is never stored. Writes only through register_shared_device / revoke_shared_device. Owners read their plant''s rows (without token_hash).';

-- Owners of the plant read the list (Setup screen); nobody reads token_hash; no direct writes.
create policy shared_devices_select on public.shared_devices for select to authenticated
  using ((select app.has_role(plant_id, array['owner']::app.member_role[])));
revoke all on public.shared_devices from anon, authenticated;
grant select (id, org_id, plant_id, label, created_at, last_used_at, revoked_at)
  on public.shared_devices to authenticated;

create function app.shared_device_token_hash(p_token text)
returns text language sql immutable set search_path = '' as $$
  select pg_catalog.encode(extensions.digest(p_token, 'sha256'), 'hex');
$$;
comment on function app.shared_device_token_hash(text) is
  'Shared plant iPad (2026-11-10): SHA-256 (hex) of a device token; only this is stored. Internal.';
revoke all on function app.shared_device_token_hash(text) from public, anon, authenticated;

-- ── Owner: make this device the plant's shared iPad ─────────────────────────
create function public.register_shared_device(p_plant_id uuid, p_label text)
returns table (id uuid, token text) language plpgsql volatile security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_org   uuid;
  v_label text := pg_catalog.btrim(coalesce(p_label, ''));
  v_token text;
  v_id    uuid;
begin
  if p_plant_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_plant_id is required';
  end if;
  if not app.has_role(p_plant_id, array['owner']::app.member_role[]) then
    raise exception 'NOT_AUTHORIZED' using detail = 'shared devices: owner only';
  end if;
  if char_length(v_label) not between 1 and 40 or not app.is_clean_text(v_label) then
    raise exception 'VALIDATION_FAILED' using detail = 'label must be 1-40 characters';
  end if;
  select p.org_id into v_org from public.plants p where p.id = p_plant_id;
  -- At most 5 live shared devices per plant: a forgotten device should be revoked, not piled up.
  if (select count(*) from public.shared_devices d
       where d.plant_id = p_plant_id and d.revoked_at is null) >= 5 then
    raise exception 'VALIDATION_FAILED' using detail = 'too many shared devices; revoke one first';
  end if;
  v_token := pg_catalog.encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.shared_devices (org_id, plant_id, label, token_hash, created_by)
  values (v_org, p_plant_id, v_label, app.shared_device_token_hash(v_token), (select auth.uid()))
  returning shared_devices.id into v_id;
  -- Audited here, not by app.audit(): the row's token_hash must never reach audit_log, and the
  -- last_used_at stamp on every name-list read is not worth a row.
  insert into public.audit_log (org_id, plant_id, actor_user_id, action, entity, entity_id, after)
  values (v_org, p_plant_id, (select auth.uid()), 'shared_devices.insert', 'shared_devices', v_id,
          pg_catalog.jsonb_build_object('id', v_id, 'label', v_label));
  return query select v_id, v_token;
end;
$$;
comment on function public.register_shared_device(uuid, text) is
  'Shared plant iPad (2026-11-10). Owner of the plant only. Returns the new device id and its token ONCE (64 hex chars); only the token''s SHA-256 is kept. At most 5 live devices per plant. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.register_shared_device(uuid, text) from public, anon;
grant execute on function public.register_shared_device(uuid, text) to authenticated;

create function public.revoke_shared_device(p_id uuid)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
declare
  v_dev public.shared_devices;
begin
  select * into v_dev from public.shared_devices where id = p_id;
  if v_dev.id is null or not app.has_role(v_dev.plant_id, array['owner']::app.member_role[]) then
    raise exception 'NOT_AUTHORIZED' using detail = 'shared devices: owner only';
  end if;
  update public.shared_devices
     set revoked_at = now(), revoked_by = (select auth.uid())
   where id = p_id and revoked_at is null;
  if not found then return false; end if;
  insert into public.audit_log (org_id, plant_id, actor_user_id, action, entity, entity_id, after)
  values (v_dev.org_id, v_dev.plant_id, (select auth.uid()), 'shared_devices.revoke', 'shared_devices',
          v_dev.id, pg_catalog.jsonb_build_object('id', v_dev.id, 'label', v_dev.label));
  return true;
end;
$$;
comment on function public.revoke_shared_device(uuid) is
  'Shared plant iPad (2026-11-10). Owner of the device''s plant only. Stops the device listing names and signing anyone in; true when it was live. Errors: NOT_AUTHORIZED.';
revoke all on function public.revoke_shared_device(uuid) from public, anon;
grant execute on function public.revoke_shared_device(uuid) to authenticated;

-- ── Service role (sign-in Edge Function): the people a live device lists ──
-- Managers and leads with a live membership on the device's plant (plant or org-wide) and a name,
-- never anyone who is an owner anywhere, never banned (deactivated) accounts. member_id is the membership id (the
-- device never learns user ids or logins). Marks the device used.
create function public.shared_device_people(p_token text)
returns table (member_id uuid, display_name text)
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_dev public.shared_devices;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return; end if;
  select * into v_dev from public.shared_devices
   where token_hash = app.shared_device_token_hash(p_token) and revoked_at is null;
  if v_dev.id is null then return; end if;
  update public.shared_devices set last_used_at = now() where id = v_dev.id;
  return query
    select distinct on (m.user_id) m.id,
           pg_catalog.btrim(p.full_name)
      from public.memberships m
      join auth.users u on u.id = m.user_id
      join public.profiles p on p.user_id = m.user_id
     where m.org_id = v_dev.org_id
       and (m.plant_id is null or m.plant_id = v_dev.plant_id)
       and m.revoked_at is null
       and m.role in ('manager', 'lead')
       and (u.banned_until is null or u.banned_until <= now())
       and u.email is not null
       -- Listed by their name only (never a username someone could try elsewhere): no name, not listed.
       and pg_catalog.btrim(coalesce(p.full_name, '')) <> ''
       -- An owner ANYWHERE (any org) is never listed: their 6 digits typed on the floor must not open
       -- an owner session (security review L2).
       and not exists (select 1 from public.memberships o
                        where o.user_id = m.user_id
                          and o.role = 'owner' and o.revoked_at is null)
     order by m.user_id, m.plant_id nulls last;
end;
$$;
comment on function public.shared_device_people(text) is
  'Shared plant iPad (2026-11-10), SERVICE ROLE only (sign-in Edge Function). The managers and leads a live device lists: membership id + display name. Unknown, malformed or revoked token → no rows. Owners (in any org), viewers, displays, banned accounts and people without a name are never listed.';
revoke all on function public.shared_device_people(text) from public, anon, authenticated;
grant execute on function public.shared_device_people(text) to service_role;

-- The login (auth email) behind one listed person, only when that person is on the device's list now.
create function public.shared_device_login(p_token text, p_member_id uuid)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid;
begin
  if p_member_id is null then return null; end if;
  select m.user_id into v_user
    from public.shared_device_people(p_token) l
    join public.memberships m on m.id = l.member_id
   where l.member_id = p_member_id;
  if v_user is null then return null; end if;
  return (select pg_catalog.lower(email) from auth.users where id = v_user);
end;
$$;
comment on function public.shared_device_login(text, uuid) is
  'Shared plant iPad (2026-11-10), SERVICE ROLE only (sign-in Edge Function): the normalised login of a person the live device lists right now, else null (unknown/revoked device, unlisted or owner account).';
revoke all on function public.shared_device_login(text, uuid) from public, anon, authenticated;
grant execute on function public.shared_device_login(text, uuid) to service_role;
