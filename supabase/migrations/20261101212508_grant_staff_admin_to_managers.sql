-- Owner decision 2026-11-01: the owner may delegate entry-staff management (add, edit, deactivate,
-- home shift, PIN set/reset; PRD A8) to specific managers. Builds on
-- 20261101210732_restrict_entry_staff_admin_to_owner (owner only).
--
-- memberships.can_manage_staff marks a delegated manager. Only manager rows may carry it (CHECK).
-- memberships UPDATE stays owner-only (policy memberships_update, unchanged), so a manager can never
-- grant the flag to themselves or anyone else. Flag changes are audited by the existing
-- memberships_audit trigger (app.audit(), before/after JSON).

alter table public.memberships
  add column can_manage_staff boolean not null default false;
alter table public.memberships
  add constraint memberships_can_manage_staff_manager_only check (not can_manage_staff or role = 'manager');
comment on column public.memberships.can_manage_staff is
  'A8 (owner decision 2026-11-01): this manager may add/edit entry staff and set PINs on the membership''s plant (or every plant of the org when plant_id is null). Manager rows only; set by the owner.';

-- ── RLS helper ────────────────────────────────────────────────────────────
-- Same shape as app.has_role: plant-scoped or org-wide membership, not revoked.
create function app.can_manage_staff(p_plant uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    join public.plants p on p.id = p_plant
    where m.user_id = (select auth.uid())
      and m.revoked_at is null
      and m.org_id = p.org_id
      and (m.plant_id is null or m.plant_id = p_plant)
      and (m.role = 'owner' or (m.role = 'manager' and m.can_manage_staff)));
$$;
comment on function app.can_manage_staff(uuid) is
  'A8 RLS helper (owner decision 2026-11-01): caller is owner on the plant, or a manager on the plant whose membership has can_manage_staff (plant or org-wide membership, not revoked).';
revoke all on function app.can_manage_staff(uuid) from public, anon;
grant execute on function app.can_manage_staff(uuid) to authenticated, service_role;

-- ── entry_staff write policies ────────────────────────────────────────────
drop policy entry_staff_insert on public.entry_staff;
drop policy entry_staff_update on public.entry_staff;
create policy entry_staff_insert on public.entry_staff for insert to authenticated
  with check ((select app.can_manage_staff(plant_id)));
create policy entry_staff_update on public.entry_staff for update to authenticated
  using ((select app.can_manage_staff(plant_id)))
  with check ((select app.can_manage_staff(plant_id)));

-- ── set_staff_pin: same body, role check via app.can_manage_staff ──────────
create or replace function public.set_staff_pin(p_staff_id uuid, p_pin text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare
  v_plant uuid;
begin
  select s.plant_id into v_plant from public.entry_staff s where s.id = p_staff_id;
  if v_plant is null or not app.can_manage_staff(v_plant) then
    raise exception 'NOT_AUTHORIZED' using detail = 'set_staff_pin requires owner, or a manager allowed to manage staff, on the staff''s plant';
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
  'A8 RPC (owner, or a manager with memberships.can_manage_staff; checked by app.can_manage_staff): set or reset a staff member''s 4-digit PIN (bcrypt). Rejects weak PINs and PINs already used by another active person in the plant. Audited as entry_staff.pin_set. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.set_staff_pin(uuid, text) from public, anon;
grant execute on function public.set_staff_pin(uuid, text) to authenticated, service_role;
