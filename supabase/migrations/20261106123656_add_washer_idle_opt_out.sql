-- Washer idle alarm toggle (owner 2026-11-06, C).
-- * memberships.notify_washer_idle (default true). An OWNER whose membership has it false stops
--   receiving washer_idle pushes and no longer sees those alerts in the Alerts tab.
-- * Safeguard (owner-approved): the manager(s) on duty ALWAYS receive washer_idle, whatever the flag.
--   The flag is only read for owner memberships; for any other role it has no effect.
-- * set_washer_idle_alert(p_membership_id, p_notify): owner of the membership's plant (or of the org for
--   an org-wide membership); the target must be an active OWNER membership (both owners have full access,
--   so either can set it for the other). Same pattern as set_alert_recipient (definer, role check
--   first, no oracle).

alter table public.memberships add column notify_washer_idle boolean not null default true;
comment on column public.memberships.notify_washer_idle is
  'Owner 2026-11-06: for OWNER memberships, whether this owner gets washer-idle alarms (push and Alerts tab). Default true. Ignored for other roles: the managers on duty always get them. Changed by an owner via set_washer_idle_alert.';
-- Same column privileges as notify_machine_down (memberships uses column grants; RLS limits writes to owners).
grant select (notify_washer_idle), insert (notify_washer_idle), update (notify_washer_idle)
  on public.memberships to authenticated;

-- Owners of the plant who want washer-idle alarms.
create function app.plant_idle_alert_owners(p_plant_id uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select distinct m.user_id from public.memberships m
    join public.plants p on p.id = p_plant_id and p.org_id = m.org_id
   where m.role = 'owner' and m.revoked_at is null and m.notify_washer_idle
     and (m.plant_id is null or m.plant_id = p_plant_id);
$$;
comment on function app.plant_idle_alert_owners(uuid) is
  'Owner 2026-11-06: user ids of the plant''s active owners (plant or org-wide) with an owner membership that has notify_washer_idle on. Internal.';
revoke all on function app.plant_idle_alert_owners(uuid) from public, anon, authenticated;
grant execute on function app.plant_idle_alert_owners(uuid) to service_role;

create or replace function app.alert_recipient_users(p_alert public.alert_events)
returns setof uuid language plpgsql stable security definer set search_path = '' as $$
begin
  if p_alert.kind = 'machine_down' then
    return query
      select distinct m.user_id from public.memberships m
        join public.plants p on p.id = p_alert.plant_id and p.org_id = m.org_id
       where m.revoked_at is null and m.role in ('owner', 'manager') and m.notify_machine_down
         and (m.plant_id is null or m.plant_id = p_alert.plant_id);
  elsif p_alert.kind = 'washer_idle' then
    -- Owners who kept it on, plus the managers on duty when it fired (always: owner-approved safeguard).
    return query
      select u from app.plant_idle_alert_owners(p_alert.plant_id) u
      union
      select u from app.managers_on_duty(p_alert.plant_id, p_alert.sent_at) u;
  elsif p_alert.kind = 'route_loaded' then
    return query select u from app.plant_owner_users(p_alert.plant_id) u;
  elsif p_alert.kind = 'task_assigned' then
    -- Only while the task is open, and only its assignees (the task text is for them).
    return query
      select x from public.tasks t cross join lateral pg_catalog.unnest(t.assignee_user_ids) x
       where t.id = p_alert.subject_id and t.plant_id = p_alert.plant_id and t.done_at is null;
  elsif p_alert.kind = 'task_done' then
    return query select u from app.plant_owner_users(p_alert.plant_id) u;
  end if;
  -- Other kinds are added by their own migrations.
end;
$$;
comment on function app.alert_recipient_users(public.alert_events) is
  'Owner 2026-11-06: who receives a push alert. machine_down: owner/manager members with notify_machine_down; washer_idle: the plant''s owners with notify_washer_idle + the managers on duty when it fired (always); route_loaded / task_done: the plant''s owners; task_assigned: the task''s assignees while it is open. Internal.';

create or replace function app.alert_visible_to(p_alert public.alert_events, p_user uuid)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
  if p_user is null then
    return false;
  end if;
  -- Every reader is an active owner or manager of the alert's plant.
  if not exists (select 1 from public.memberships m
                  join public.plants p on p.id = p_alert.plant_id and p.org_id = m.org_id
                  where m.user_id = p_user and m.revoked_at is null and m.role in ('owner', 'manager')
                    and (m.plant_id is null or m.plant_id = p_alert.plant_id)) then
    return false;
  end if;
  if p_alert.kind = 'machine_down' then
    return exists (select 1 from public.memberships m
                    join public.plants p on p.id = p_alert.plant_id and p.org_id = m.org_id
                    where m.user_id = p_user and m.revoked_at is null and m.role in ('owner', 'manager')
                      and m.notify_machine_down and (m.plant_id is null or m.plant_id = p_alert.plant_id));
  elsif p_alert.kind = 'washer_idle' then
    return exists (select 1 from app.plant_idle_alert_owners(p_alert.plant_id) u where u = p_user)
        or exists (select 1 from app.managers_on_duty(p_alert.plant_id, p_alert.sent_at) u where u = p_user);
  elsif p_alert.kind = 'task_assigned' then
    return coalesce(p_alert.dedupe_key, '0') = '0'
       and exists (select 1 from public.tasks t
                    where t.id = p_alert.subject_id and t.plant_id = p_alert.plant_id and p_user = any (t.assignee_user_ids));
  elsif p_alert.kind in ('task_done', 'route_loaded') then
    return exists (select 1 from app.plant_owner_users(p_alert.plant_id) u where u = p_user);
  end if;
  return false;
end;
$$;
comment on function app.alert_visible_to(public.alert_events, uuid) is
  'Alerts tab (2026-11-06): true when p_user would receive this push alert (same rules as app.alert_recipient_users, applied to history: washer_idle to owners with notify_washer_idle and the managers on duty when it fired; task_assigned listed once per task, for its assignees even after done). Internal.';

-- ── set_washer_idle_alert ─────────────────────────────────────────────────
create function public.set_washer_idle_alert(p_membership_id uuid, p_notify boolean)
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
    raise exception 'NOT_AUTHORIZED' using detail = 'set_washer_idle_alert requires owner of the membership''s plant';
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
  'Owner 2026-11-06 RPC (owner of the membership''s plant, or of the org for an org-wide membership; definer, role check first, no oracle): turns washer-idle alarms (push + Alerts tab) on or off for one OWNER membership. Managers on duty always get them, so other roles are rejected. Returns the memberships row. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.set_washer_idle_alert(uuid, boolean) from public, anon;
grant execute on function public.set_washer_idle_alert(uuid, boolean) to authenticated, service_role;
