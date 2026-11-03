-- PRD A4 (owner decision 2026-11-03; security review M2): a temporary password must be changed
-- before the account can do anything. manage-users sets app_metadata.must_change_password on
-- create and reset, and only its change_own_password action clears it. Until then the JWT carries
-- the flag, and the role helpers below answer false, so every RLS policy and role-checked RPC
-- built on them denies. That covers PostgREST and RPC calls as well as the UI.
--
-- Not gated (unchanged): languages_select (true), the own-profile policies (auth.uid()), and the
-- display device helpers' own checks. app.is_display() calls app.has_role(), but display device
-- accounts never carry the flag. A token minted before a reset keeps working until it expires
-- (≤ 1 h). The flag is read from the token, not from auth.users.

create function app.password_ok()
returns boolean language sql stable set search_path = '' as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'must_change_password')::boolean, false) = false;
$$;
comment on function app.password_ok() is
  'A4 (2026-11-03): false while the caller''s JWT has app_metadata.must_change_password = true (temporary password not yet changed). Gates app.has_role, app.has_org_role and app.can_manage_staff.';
revoke all on function app.password_ok() from public, anon;
grant execute on function app.password_ok() to authenticated;

-- Bodies identical to 20261101115534 / 20261101212508, plus the password_ok() gate.
create or replace function app.has_role(p_plant uuid, p_roles app.member_role[])
returns boolean language sql stable security definer set search_path = '' as $$
  select (select app.password_ok()) and exists (
    select 1 from public.memberships m
    join public.plants p on p.id = p_plant
    where m.user_id = (select auth.uid())
      and m.revoked_at is null
      and m.org_id = p.org_id
      and (m.plant_id is null or m.plant_id = p_plant)
      and m.role = any (p_roles));
$$;
comment on function app.has_role(uuid, app.member_role[]) is
  '§4.7 RLS helper: caller has one of p_roles on the plant (plant or org-wide membership, not revoked) and no pending forced password change (app.password_ok, A4).';

create or replace function app.has_org_role(p_org uuid, p_roles app.member_role[])
returns boolean language sql stable security definer set search_path = '' as $$
  select (select app.password_ok()) and exists (
    select 1 from public.memberships m
    where m.user_id = (select auth.uid())
      and m.revoked_at is null
      and m.org_id = p_org
      and m.plant_id is null
      and m.role = any (p_roles));
$$;
comment on function app.has_org_role(uuid, app.member_role[]) is
  '§4.7 RLS helper: caller has an org-wide (plant_id null) membership in p_org with one of p_roles, and no pending forced password change (app.password_ok, A4).';

create or replace function app.can_manage_staff(p_plant uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select app.password_ok()) and exists (
    select 1 from public.memberships m
    join public.plants p on p.id = p_plant
    where m.user_id = (select auth.uid())
      and m.revoked_at is null
      and m.org_id = p.org_id
      and (m.plant_id is null or m.plant_id = p_plant)
      and (m.role = 'owner' or (m.role = 'manager' and m.can_manage_staff)));
$$;
comment on function app.can_manage_staff(uuid) is
  'A8 RLS helper (owner decision 2026-11-01): caller is owner on the plant, or a manager on the plant whose membership has can_manage_staff (plant or org-wide membership, not revoked), with no pending forced password change (app.password_ok, A4).';

-- create or replace keeps the existing grants; restated here so the intent is explicit.
revoke all on function app.has_role(uuid, app.member_role[]) from public, anon;
revoke all on function app.has_org_role(uuid, app.member_role[]) from public, anon;
revoke all on function app.can_manage_staff(uuid) from public, anon;
grant execute on function app.has_role(uuid, app.member_role[]) to authenticated, service_role;
grant execute on function app.has_org_role(uuid, app.member_role[]) to authenticated, service_role;
grant execute on function app.can_manage_staff(uuid) to authenticated, service_role;
