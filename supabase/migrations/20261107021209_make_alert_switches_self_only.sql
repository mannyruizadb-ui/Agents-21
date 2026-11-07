-- Alert switches are SELF-ONLY for owners (owner 2026-11-07, "green light"; security review 2026-11-07
-- note "co-owner can silence father's levels").
--
-- * set_alert_level and set_washer_idle_alert: the caller must be an owner of the membership's plant (or
--   org, for an org-wide membership) AND the membership must be the caller's own. Another person's
--   membership, a missing id and another tenant's id all give the same NOT_AUTHORIZED (no oracle).
-- * set_alert_recipient (machine-down push): unchanged for managers' memberships (owners still turn their
--   managers' machine-down alerts on and off); an owner may change only their OWN owner memberships, never
--   another owner's (NOT_AUTHORIZED, same answer as a missing id).
-- * The memberships table keeps its owner UPDATE policy (and its table-wide grant, L3 open), so a trigger
--   closes the direct path too: a signed-in caller (auth.uid() set, also inside definer RPCs) may not change
--   alert_levels or notify_washer_idle of another user's membership, nor notify_machine_down of another
--   user's OWNER membership; on INSERT for another user those columns must keep their defaults. The service
--   role and migrations (auth.uid() null) are not limited; anon has no privileges on memberships
--   (20261107010437), so the null case is not an anon oracle. Rows the caller cannot update are filtered by
--   RLS before the trigger runs (no oracle).

create function app.guard_member_alert_settings()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    return new;                                  -- service role / migrations
  end if;
  if tg_op = 'INSERT' then
    if new.user_id is distinct from v_uid
       and (new.alert_levels is distinct from app.default_alert_levels() or new.notify_washer_idle is distinct from true) then
      raise exception 'NOT_AUTHORIZED' using detail = 'alert settings: only the person themselves changes them';
    end if;
    return new;
  end if;
  if old.user_id is distinct from v_uid or new.user_id is distinct from v_uid then
    if new.alert_levels is distinct from old.alert_levels
       or new.notify_washer_idle is distinct from old.notify_washer_idle
       or (new.notify_machine_down is distinct from old.notify_machine_down
           and (old.role = 'owner' or new.role = 'owner')) then
      raise exception 'NOT_AUTHORIZED' using detail = 'alert settings: an owner changes only their own (machine-down alerts of managers excepted)';
    end if;
  end if;
  return new;
end;
$$;
comment on function app.guard_member_alert_settings() is
  'Owner 2026-11-07: BEFORE INSERT/UPDATE trigger on memberships. A signed-in caller may change alert_levels and notify_washer_idle only on their own memberships, and notify_machine_down of an owner membership only when it is their own (managers'' machine-down flags stay owner-settable). On INSERT for another user those columns must keep their defaults. Service role / migrations (no auth.uid()) are not limited. NOT_AUTHORIZED otherwise.';
revoke all on function app.guard_member_alert_settings() from public, anon, authenticated;
create trigger memberships_guard_alert_settings before insert or update on public.memberships
  for each row execute function app.guard_member_alert_settings();

-- ── set_alert_level: own owner memberships only ───────────────────────────
create or replace function public.set_alert_level(p_membership_id uuid, p_kind text, p_level text)
returns public.memberships language plpgsql volatile security definer set search_path = '' as $$
declare
  v public.memberships;
begin
  -- Role check FIRST: the caller must own the membership's plant (or org, for an org-wide membership)
  -- AND it must be the caller's own. Missing, foreign and other people's ids: the same NOT_AUTHORIZED.
  select m.* into v from public.memberships m where m.id = p_membership_id;
  if v.id is null
     or v.user_id is distinct from (select auth.uid())
     or not (case when v.plant_id is null then app.has_org_role(v.org_id, '{owner}')
                  else app.has_role(v.plant_id, '{owner}') end) then
    raise exception 'NOT_AUTHORIZED' using detail = 'set_alert_level: only on your own owner membership';
  end if;
  if p_kind is null or not (p_kind = any (app.owner_alert_kinds())) then
    raise exception 'VALIDATION_FAILED' using detail = 'p_kind: customer_delivery, estimate_entered, rewash_added or account_locked';
  end if;
  if p_level is null or p_level not in ('push', 'quiet', 'off') then
    raise exception 'VALIDATION_FAILED' using detail = 'p_level: push, quiet or off';
  end if;
  if v.revoked_at is not null then
    raise exception 'VALIDATION_FAILED' using detail = 'membership: revoked';
  end if;
  if v.role <> 'owner' then
    raise exception 'VALIDATION_FAILED' using detail = 'only owner memberships have alert levels';
  end if;
  update public.memberships m
     set alert_levels = m.alert_levels || pg_catalog.jsonb_build_object(p_kind, p_level)
   where m.id = v.id
  returning m.* into v;
  return v;
end;
$$;
comment on function public.set_alert_level(uuid, text, text) is
  'Owner 2026-11-06 RPC, SELF-ONLY since 2026-11-07 (definer, role check first, no oracle): the caller sets the level of one of THEIR OWN owner memberships (they must own its plant, or its org for an org-wide membership) for an owner information alert kind (customer_delivery | estimate_entered | rewash_added | account_locked) to push (push + Alerts tab), quiet (Alerts tab and badge, no push) or off (hidden). Another owner''s membership gives NOT_AUTHORIZED. Returns the memberships row (alert_levels). Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';

-- ── set_washer_idle_alert: own owner memberships only ─────────────────────
create or replace function public.set_washer_idle_alert(p_membership_id uuid, p_notify boolean)
returns public.memberships language plpgsql security definer set search_path = '' as $$
declare
  v public.memberships;
begin
  -- Role check FIRST (same rule as set_alert_level): own membership of a plant/org the caller owns.
  select m.* into v from public.memberships m where m.id = p_membership_id;
  if v.id is null
     or v.user_id is distinct from (select auth.uid())
     or not (case when v.plant_id is null then app.has_org_role(v.org_id, '{owner}')
                  else app.has_role(v.plant_id, '{owner}') end) then
    raise exception 'NOT_AUTHORIZED' using detail = 'set_washer_idle_alert: only on your own owner membership';
  end if;
  if p_notify is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_notify: true or false';
  end if;
  if v.revoked_at is not null then
    raise exception 'VALIDATION_FAILED' using detail = 'membership: revoked';
  end if;
  if v.role <> 'owner' then
    raise exception 'VALIDATION_FAILED' using detail = 'only owner memberships have this setting: the managers on duty always get washer-idle alarms';
  end if;
  update public.memberships m set notify_washer_idle = p_notify where m.id = v.id returning m.* into v;
  return v;
end;
$$;
comment on function public.set_washer_idle_alert(uuid, boolean) is
  'Owner 2026-11-06 RPC, SELF-ONLY since 2026-11-07 (definer, role check first, no oracle): the caller turns the washer-idle alarm on or off for one of THEIR OWN owner memberships (they must own its plant, or its org for an org-wide membership). Another owner''s membership gives NOT_AUTHORIZED; manager memberships have no switch (the managers on duty always get it). Returns the memberships row. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';

-- ── set_alert_recipient: managers as before; owners only themselves ───────
create or replace function public.set_alert_recipient(p_membership_id uuid, p_notify boolean)
returns public.memberships language plpgsql security definer set search_path = '' as $$
declare
  v public.memberships;
begin
  -- Role check FIRST: the caller must own the membership's plant (or org, for an org-wide membership);
  -- an OWNER membership must also be the caller's own (2026-11-07). Missing, foreign and other owners'
  -- ids give the same NOT_AUTHORIZED.
  select m.* into v from public.memberships m where m.id = p_membership_id;
  if v.id is null
     or not (case when v.plant_id is null then app.has_org_role(v.org_id, '{owner}')
                  else app.has_role(v.plant_id, '{owner}') end)
     or (v.role = 'owner' and v.user_id is distinct from (select auth.uid())) then
    raise exception 'NOT_AUTHORIZED' using detail = 'set_alert_recipient requires owner of the membership''s plant; another owner''s setting is theirs';
  end if;
  if p_notify is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_notify: true or false';
  end if;
  if v.revoked_at is not null then
    raise exception 'VALIDATION_FAILED' using detail = 'membership: revoked';
  end if;
  if p_notify and v.role not in ('owner', 'manager') then
    raise exception 'VALIDATION_FAILED' using detail = 'only owner and manager memberships can receive machine-down alerts';
  end if;
  update public.memberships m set notify_machine_down = p_notify where m.id = v.id returning m.* into v;
  return v;
end;
$$;
comment on function public.set_alert_recipient(uuid, boolean) is
  'Owner 2026-11-04 RPC (owner of the membership''s plant, or of the org for an org-wide membership; definer, role check first, no oracle): turns machine-down push alerts on or off for a membership. Managers'' memberships: any owner of the plant (as before). Owner memberships: only the owner themselves (2026-11-07; another owner''s gives NOT_AUTHORIZED). Only owner and manager memberships can be turned on. Returns the memberships row. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
