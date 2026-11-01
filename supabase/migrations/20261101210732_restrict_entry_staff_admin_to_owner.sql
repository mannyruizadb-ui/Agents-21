-- Owner decision 2026-11-01: only the owner manages entry staff (add, edit, deactivate, home shift,
-- PIN set/reset). Managers and leads keep read access to non-secret columns (picker, entry lists).
-- PRD A8 v1.6. Replaces the owner/manager write rights from 20261101115538.

drop policy entry_staff_insert on public.entry_staff;
drop policy entry_staff_update on public.entry_staff;
create policy entry_staff_insert on public.entry_staff for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner}')));
create policy entry_staff_update on public.entry_staff for update to authenticated
  using ((select app.has_role(plant_id, '{owner}')))
  with check ((select app.has_role(plant_id, '{owner}')));

create or replace function public.set_staff_pin(p_staff_id uuid, p_pin text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare
  v_plant uuid;
begin
  select s.plant_id into v_plant from public.entry_staff s where s.id = p_staff_id;
  if v_plant is null or not app.has_role(v_plant, '{owner}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'set_staff_pin requires owner on the staff''s plant';
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
  'A8 RPC (owner only): set or reset a staff member''s 4-digit PIN (bcrypt). Rejects weak PINs and PINs already used by another active person in the plant. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.set_staff_pin(uuid, text) from public, anon;
grant execute on function public.set_staff_pin(uuid, text) to authenticated, service_role;
