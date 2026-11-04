-- Who gets machine-down push alerts (owner 2026-11-04: "selected managers or owners").
-- memberships.notify_machine_down: true by default for owner memberships, false for every other role
-- (set by a BEFORE INSERT trigger when the insert leaves it null; existing rows backfilled the same
-- way). Only owner and manager memberships ever receive alerts (app.pending_machine_down_alerts).
-- The owner changes it with set_alert_recipient (definer, no oracle). The memberships UPDATE policy
-- already limits direct edits to owners, so the RPC is the convenient path, not a new privilege.
-- The People screen reads it from memberships (SELECT policy: owner/manager of the plant or org).

alter table public.memberships add column notify_machine_down boolean;
update public.memberships set notify_machine_down = (role = 'owner') where notify_machine_down is null;
alter table public.memberships alter column notify_machine_down set not null;
comment on column public.memberships.notify_machine_down is
  'Owner 2026-11-04: this member gets machine-down push alerts for the membership''s plant (org-wide: every plant). Default true for owner, false otherwise; only owner/manager memberships are ever alerted. Changed by the owner via set_alert_recipient.';

create function app.default_notify_machine_down()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.notify_machine_down := coalesce(new.notify_machine_down, new.role = 'owner');
  return new;
end;
$$;
comment on function app.default_notify_machine_down() is
  'BEFORE INSERT on memberships: notify_machine_down defaults to true for owner memberships and false for other roles when the insert leaves it null (owner 2026-11-04).';
revoke all on function app.default_notify_machine_down() from public, anon, authenticated;
create trigger memberships_default_notify before insert on public.memberships
  for each row execute function app.default_notify_machine_down();

-- ── set_alert_recipient ───────────────────────────────────────────────────
create function public.set_alert_recipient(p_membership_id uuid, p_notify boolean)
returns public.memberships language plpgsql volatile security definer set search_path = '' as $$
declare
  v public.memberships;
begin
  -- Role check FIRST: the caller must be an owner of the membership's plant (or of its org for an
  -- org-wide membership). Missing and foreign ids give the same NOT_AUTHORIZED.
  select m.* into v from public.memberships m where m.id = p_membership_id;
  if v.id is null
     or not (case when v.plant_id is null then app.has_org_role(v.org_id, '{owner}')
                  else app.has_role(v.plant_id, '{owner}') end) then
    raise exception 'NOT_AUTHORIZED' using detail = 'set_alert_recipient requires owner of the membership''s plant';
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
  'Owner 2026-11-04 RPC (owner of the membership''s plant, or of the org for an org-wide membership; definer, role check first, no oracle): turns machine-down push alerts on or off for one membership. Only owner/manager memberships can be turned on; revoked memberships are rejected. Returns the memberships row. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.set_alert_recipient(uuid, boolean) from public, anon;
grant execute on function public.set_alert_recipient(uuid, boolean) to authenticated, service_role;
