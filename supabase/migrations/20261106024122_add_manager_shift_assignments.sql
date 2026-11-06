-- Manager on duty = the shift schedule (owner 2026-11-06, round 2). The owner assigns each manager
-- membership to the shift(s) that manager usually works; app.managers_on_duty(plant, at) returns the
-- managers whose assigned shift has an instance (not skipped) running at that moment. Tasks sent to
-- "manager on duty", route loading and the washer-idle alarm use it.
-- Schedule data only: nothing reports on it per person (no counts, no hours, no history views).
--
-- * public.manager_shift_assignments (membership × shift): owner-only writes (RLS + column grants),
--   owner/manager reads, audited; deactivate (active = false), never delete.
-- * The membership must be an active MANAGER membership of the shift's plant (or org-wide in its org).

create table public.manager_shift_assignments (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  membership_id uuid not null references public.memberships(id),
  shift_id      uuid not null,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (shift_id, plant_id) references public.shifts(id, plant_id),
  unique (membership_id, shift_id)
);
alter table public.manager_shift_assignments enable row level security;
create index manager_shift_assignments_plant_org_idx on public.manager_shift_assignments (plant_id, org_id);
create index manager_shift_assignments_shift_plant_idx on public.manager_shift_assignments (shift_id, plant_id);
comment on table public.manager_shift_assignments is
  'Owner 2026-11-06: which shifts each manager usually works (manager on duty = the schedule). Owner-only edits; deactivate, never delete. Schedule data only: never reported per person.';

create function app.check_manager_assignment()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- No oracle: only owners may write (RLS), so anyone else's row is left to RLS (42501) unvalidated.
  if (select auth.uid()) is not null and not app.has_role(new.plant_id, '{owner}') then
    return new;
  end if;
  if not exists (
       select 1 from public.memberships m
        where m.id = new.membership_id and m.role = 'manager' and m.revoked_at is null
          and m.org_id = new.org_id and (m.plant_id is null or m.plant_id = new.plant_id)) then
    raise exception 'VALIDATION_FAILED' using detail = 'membership_id: not an active manager membership of this plant';
  end if;
  return new;
end;
$$;
comment on function app.check_manager_assignment() is
  'BEFORE INSERT/UPDATE on manager_shift_assignments: the membership must be an active manager membership of the row''s plant (org-wide allowed). VALIDATION_FAILED otherwise; rows from non-owners pass to RLS (no oracle).';
revoke all on function app.check_manager_assignment() from public, anon, authenticated;

create trigger manager_shift_assignments_check before insert or update of membership_id, plant_id, org_id, active
  on public.manager_shift_assignments for each row execute function app.check_manager_assignment();
create trigger manager_shift_assignments_touch_updated_at before update on public.manager_shift_assignments
  for each row execute function app.touch_updated_at();
create trigger manager_shift_assignments_audit after insert or update on public.manager_shift_assignments
  for each row execute function app.audit();

create policy manager_shift_assignments_select on public.manager_shift_assignments for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')));
create policy manager_shift_assignments_insert on public.manager_shift_assignments for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner}')));
create policy manager_shift_assignments_update on public.manager_shift_assignments for update to authenticated
  using ((select app.has_role(plant_id, '{owner}')))
  with check ((select app.has_role(plant_id, '{owner}')));
revoke all on public.manager_shift_assignments from anon, authenticated;
grant select on public.manager_shift_assignments to authenticated;
grant insert (org_id, plant_id, membership_id, shift_id, active) on public.manager_shift_assignments to authenticated;
grant update (active) on public.manager_shift_assignments to authenticated;

create function app.managers_on_duty(p_plant_id uuid, p_at timestamptz)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select distinct m.user_id
    from public.manager_shift_assignments a
    join public.memberships m on m.id = a.membership_id and m.role = 'manager' and m.revoked_at is null
    join public.shift_instances si on si.shift_id = a.shift_id and si.plant_id = a.plant_id
   where a.plant_id = p_plant_id and a.active
     and si.skipped_at is null and si.starts_at <= p_at and si.ends_at > p_at;
$$;
comment on function app.managers_on_duty(uuid, timestamptz) is
  'Owner 2026-11-06: user ids of the managers on duty at p_at = active manager memberships assigned to a shift whose (not skipped) instance covers p_at. Internal (service role / definer RPCs); never reported per person.';
revoke all on function app.managers_on_duty(uuid, timestamptz) from public, anon, authenticated;
grant execute on function app.managers_on_duty(uuid, timestamptz) to service_role;
