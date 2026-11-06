-- The Alerts tab (redesign, 2026-11-06): each owner / manager sees the push alerts meant for them, and a
-- badge count. Same recipient rules as the push (app.alert_recipient_users), applied to the reader:
--   machine_down  owners and managers with notify_machine_down
--   washer_idle   the plant's owners, and the managers who were on duty when it fired
--   task_assigned only the task's assignees (one row per task: the first alert; reminders are not
--                 listed again), whether or not the task is done since
--   task_done     the plant's owners
--   route_loaded  the plant's owners
-- Payloads are app.alert_payload (no free text except a task's own text to its recipients; no names).
-- still_current: machine still down / washer still idle / task still open / route still loaded;
-- false for task_done (informational).

create function app.alert_visible_to(p_alert public.alert_events, p_user uuid)
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
    return exists (select 1 from app.plant_owner_users(p_alert.plant_id) u where u = p_user)
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
  'Alerts tab (2026-11-06): true when p_user would receive this push alert (same rules as app.alert_recipient_users, applied to history; task_assigned listed once per task, for its assignees even after done). Internal.';
revoke all on function app.alert_visible_to(public.alert_events, uuid) from public, anon, authenticated;
grant execute on function app.alert_visible_to(public.alert_events, uuid) to service_role;

create function public.get_my_alerts(p_plant_id uuid, p_limit int default 50)
returns table (alert_id uuid, kind text, created_at timestamptz, payload jsonb, still_current boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_plant uuid;
  v_me    uuid := (select auth.uid());
begin
  select p.id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant is null or not app.has_role(v_plant, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_my_alerts requires owner or manager on the plant';
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'VALIDATION_FAILED' using detail = 'p_limit: 1–200';
  end if;
  return query
  select a.id, a.kind, a.sent_at, x.payload,
         case a.kind
           when 'machine_down'  then coalesce((x.payload ->> 'still_down')::boolean, false)
           when 'washer_idle'   then coalesce((x.payload ->> 'still_idle')::boolean, false)
           when 'task_assigned' then (x.payload ->> 'done_at') is null
           when 'route_loaded'  then coalesce((
             select e2.loaded from public.route_load_events e
               join public.route_load_events e2 on e2.route_id = e.route_id and e2.plant_id = e.plant_id and e2.load_date = e.load_date
              where e.id = a.subject_id and e.plant_id = a.plant_id
              order by e2.occurred_at desc, e2.seq desc limit 1), false)
           else false end
    from public.alert_events a
   cross join lateral (select app.alert_payload(a) as payload) x
   where a.plant_id = v_plant
     and a.kind = any (app.push_alert_kinds())
     and a.sent_at > pg_catalog.now() - interval '7 days'
     and app.alert_visible_to(a, v_me)
   order by a.sent_at desc, a.id desc
   limit p_limit;
end;
$$;
comment on function public.get_my_alerts(uuid, int) is
  'Alerts tab (2026-11-06; owner/manager of the plant; definer, role check first): the push alerts of the last 7 days that the caller would receive (same rules as the push; task_assigned once per task), newest first, at most p_limit (1–200, default 50). Columns: alert_id, kind, created_at, payload (app.alert_payload: no free text except a task''s text for its recipients, no names), still_current (still down / still idle / task open / route still loaded; false for task_done). Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.get_my_alerts(uuid, int) from public, anon;
grant execute on function public.get_my_alerts(uuid, int) to authenticated, service_role;

create function public.get_my_alert_count(p_plant_id uuid)
returns int language plpgsql stable security definer set search_path = '' as $$
declare
  v_plant uuid;
  v_n     int;
begin
  select p.id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant is null or not app.has_role(v_plant, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_my_alert_count requires owner or manager on the plant';
  end if;
  select count(*)::int into v_n
    from public.alert_events a
   where a.plant_id = v_plant
     and a.kind = any (app.push_alert_kinds())
     and a.sent_at > pg_catalog.now() - interval '24 hours'
     and app.alert_visible_to(a, (select auth.uid()));
  return v_n;
end;
$$;
comment on function public.get_my_alert_count(uuid) is
  'Alerts tab badge (2026-11-06; owner/manager; definer, role check first): how many of the caller''s alerts (same rules as get_my_alerts) were written in the last 24 hours. Errors: NOT_AUTHORIZED.';
revoke all on function public.get_my_alert_count(uuid) from public, anon;
grant execute on function public.get_my_alert_count(uuid) to authenticated, service_role;
