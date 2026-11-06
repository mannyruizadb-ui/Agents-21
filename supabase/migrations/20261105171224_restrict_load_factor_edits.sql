-- Owner 2026-11-05: load factors (loads per basket / bin and whether a group takes basket / bin
-- estimates) are edited by OWNERS only, plus managers the owner grants, like can_manage_staff.
--
-- * memberships.can_edit_load_factors (manager memberships only; the owner sets it on the People
--   screen through the existing owner-only memberships UPDATE).
-- * app.can_edit_load_factors(plant): owner, or an active manager membership with the grant (and the
--   password-change gate passed).
-- * A BEFORE INSERT/UPDATE guard on wash_groups: changing loads_per_basket, loads_per_bin,
--   allow_basket_estimates or allow_bin_estimates (or inserting a group with any of them set) needs
--   that permission; otherwise NOT_AUTHORIZED. Other wash-group fields stay owner/manager editable.
--   Rows the caller has no role on pass through to RLS (no cross-tenant oracle); service role /
--   postgres (auth.uid() null) are not checked.

alter table public.memberships
  add column can_edit_load_factors boolean not null default false,
  add constraint memberships_can_edit_load_factors_manager_only check (not can_edit_load_factors or role = 'manager');
comment on column public.memberships.can_edit_load_factors is
  'Owner 2026-11-05: this manager may edit wash-group load factors (loads per basket / bin, allow basket / bin estimates). Owners always may. Set by the owner.';

create function app.can_edit_load_factors(p_plant uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select app.password_ok()) and exists (
    select 1 from public.memberships m
    join public.plants p on p.id = p_plant
    where m.user_id = (select auth.uid())
      and m.revoked_at is null
      and m.org_id = p.org_id
      and (m.plant_id is null or m.plant_id = p_plant)
      and (m.role = 'owner' or (m.role = 'manager' and m.can_edit_load_factors)));
$$;
comment on function app.can_edit_load_factors(uuid) is
  'Owner 2026-11-05: caller is an owner of the plant (or its org), or a manager the owner granted can_edit_load_factors; password-change gate applies.';
revoke all on function app.can_edit_load_factors(uuid) from public, anon, authenticated;
grant execute on function app.can_edit_load_factors(uuid) to service_role;

create function app.guard_load_factor_edit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    return new;                                  -- service role / migrations
  end if;
  if not app.has_role(new.plant_id, '{owner,manager,lead,viewer}') then
    return new;                                  -- RLS rejects it; no oracle
  end if;
  if (tg_op = 'INSERT' and (new.loads_per_basket is not null or new.loads_per_bin is not null
                            or new.allow_basket_estimates or new.allow_bin_estimates))
     or (tg_op = 'UPDATE' and (new.loads_per_basket, new.loads_per_bin, new.allow_basket_estimates, new.allow_bin_estimates)
                              is distinct from
                              (old.loads_per_basket, old.loads_per_bin, old.allow_basket_estimates, old.allow_bin_estimates)) then
    if not app.can_edit_load_factors(new.plant_id) then
      raise exception 'NOT_AUTHORIZED' using detail = 'load factors: owner, or a manager the owner granted can_edit_load_factors';
    end if;
  end if;
  return new;
end;
$$;
comment on function app.guard_load_factor_edit() is
  'Owner 2026-11-05: BEFORE INSERT/UPDATE on wash_groups: changing loads_per_basket / loads_per_bin / allow_basket_estimates / allow_bin_estimates needs app.can_edit_load_factors (NOT_AUTHORIZED). Rows without a caller role pass to RLS.';
revoke all on function app.guard_load_factor_edit() from public, anon, authenticated;
create trigger wash_groups_guard_load_factors before insert or update on public.wash_groups
  for each row execute function app.guard_load_factor_edit();
