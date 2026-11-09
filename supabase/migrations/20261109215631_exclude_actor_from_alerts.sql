-- No alerts for your own actions (owner 2026-11-09, review item 9). The person whose action raised an alert is
-- neither pushed nor shown it in their Alerts tab: an owner who marks a washer down, finishes a task, records an
-- AA drop-off or enters estimates does not get told about it.
--
-- The actor is DERIVED from the alert's subject row (app.alert_actor), not stored on alert_events, so no new
-- per-person data is kept: each subject already records who entered it (PRD A8 "who entered"):
--   machine_down      → machine_status_events.entered_by (the down event)
--   task_assigned     → tasks.created_by, first alert only (dedupe_key '0'); reminders are the system's (no actor)
--   task_done         → tasks.done_by
--   route_loaded      → route_load_events.entered_by
--   customer_delivery → customer_deliveries.entered_by
--   rewash_added      → queue_items.created_by
--   estimate_entered  → soil_estimates.entered_by (the batch's first estimate; a batch is one account's)
--   washer_idle, account_locked, estimate_stale, device_offline, import_failed, shift_generation_failed → none
--     (raised by the system: cron or sign-in).
-- The actor never leaves the database: app.alert_actor is internal, alert_visible_to returns a boolean, and no
-- payload carries it. A caller only learns that an alert of THEIR OWN action is hidden from them.
--
-- * app.alert_audience(alert)        = the previous app.alert_recipient_users body (who the kind goes to).
-- * app.alert_recipient_users(alert) = audience minus the actor (push; used by app.pending_push_notifications).
-- * app.alert_visible_to(alert, user) = false for the actor (Alerts tab, count, clear).
-- * app.raise_owner_alert: '{}' (pending push) only when app.alert_recipient_users (audience minus the actor
--   from the subject row) is non-empty; otherwise '{quiet}', so an alert whose only push owner is its actor is
--   not left pending.
-- * Legacy app.pending_machine_down_alerts / claim_machine_down_alerts and their public wrappers
--   get_pending_push_alerts / claim_push_alerts: service_role execute revoked (unused by send-alerts).

create function app.alert_actor(p_alert public.alert_events)
returns uuid language sql stable security definer set search_path = '' as $$
  select case p_alert.kind
    when 'machine_down' then
      (select e.entered_by from public.machine_status_events e
        where e.id = p_alert.subject_id and e.plant_id = p_alert.plant_id)
    when 'task_assigned' then
      case when coalesce(p_alert.dedupe_key, '0') = '0' then
        (select t.created_by from public.tasks t where t.id = p_alert.subject_id and t.plant_id = p_alert.plant_id) end
    when 'task_done' then
      (select t.done_by from public.tasks t where t.id = p_alert.subject_id and t.plant_id = p_alert.plant_id)
    when 'route_loaded' then
      (select e.entered_by from public.route_load_events e
        where e.id = p_alert.subject_id and e.plant_id = p_alert.plant_id)
    when 'customer_delivery' then
      (select d.entered_by from public.customer_deliveries d
        where d.id = p_alert.subject_id and d.plant_id = p_alert.plant_id)
    when 'rewash_added' then
      (select q.created_by from public.queue_items q where q.id = p_alert.subject_id and q.plant_id = p_alert.plant_id)
    when 'estimate_entered' then
      (select s.entered_by from public.soil_estimates s where s.id = p_alert.subject_id and s.plant_id = p_alert.plant_id)
  end;
$$;
comment on function app.alert_actor(public.alert_events) is
  'Owner 2026-11-09 (no alerts for your own actions): the account whose action raised the alert, read from the alert''s subject row (machine_down: down event entered_by; task_assigned first alert: task created_by; task_done: done_by; route_loaded, customer_delivery, estimate_entered: entered_by; rewash_added: queue item created_by). Null for system-raised kinds and task reminders. Internal: never returned to a client.';
revoke all on function app.alert_actor(public.alert_events) from public, anon, authenticated;

-- The previous recipient rules, unchanged, under a new name.
create function app.alert_audience(p_alert public.alert_events)
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
  elsif p_alert.kind = any (app.owner_alert_kinds()) then
    -- Owner information kinds: pushed only to owners whose level is push (quiet = Alerts tab only).
    return query select u from app.plant_owner_alert_users(p_alert.plant_id, p_alert.kind, '{push}') u;
  end if;
end;
$$;
comment on function app.alert_audience(public.alert_events) is
  'Who a kind is pushed to, before removing the actor (the rules of app.alert_recipient_users up to 2026-11-09): machine_down: owner/manager members with notify_machine_down; washer_idle: owners with notify_washer_idle + managers on duty when it fired; route_loaded / task_done: the plant''s owners; task_assigned: the open task''s assignees; owner information kinds: owners whose level is push. Internal.';
revoke all on function app.alert_audience(public.alert_events) from public, anon, authenticated;

create or replace function app.alert_recipient_users(p_alert public.alert_events)
returns setof uuid language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid := app.alert_actor(p_alert);
begin
  return query
    select u from app.alert_audience(p_alert) u
     where u is distinct from v_actor;
end;
$$;
comment on function app.alert_recipient_users(public.alert_events) is
  'Owner 2026-11-06, 2026-11-09: who receives a push alert: app.alert_audience (machine_down: owner/manager members with notify_machine_down; washer_idle: owners with notify_washer_idle + the managers on duty when it fired; route_loaded / task_done: the plant''s owners; task_assigned: the open task''s assignees; customer_delivery / estimate_entered / rewash_added / account_locked: owners whose level is push) MINUS the account whose action raised it (app.alert_actor). Internal.';

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
  -- 2026-11-09: never your own action.
  if p_user = app.alert_actor(p_alert) then
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
  elsif p_alert.kind = any (app.owner_alert_kinds()) then
    -- Owners only; push and quiet show in the Alerts tab, off hides the kind.
    return coalesce(app.owner_alert_level(p_alert.plant_id, p_user, p_alert.kind) in ('push', 'quiet'), false);
  end if;
  return false;
end;
$$;
comment on function app.alert_visible_to(public.alert_events, uuid) is
  'Alerts tab (2026-11-06, 2026-11-09): true when p_user would see this alert: never the account whose action raised it (app.alert_actor); otherwise the push recipient rules applied to history (washer_idle to owners with notify_washer_idle and the managers on duty when it fired; task_assigned listed once per task, for its assignees even after done), and for the owner information kinds (customer_delivery, estimate_entered, rewash_added, account_locked) the plant''s owners whose level is push or quiet (off hides them). Internal.';

create or replace function app.raise_owner_alert(p_org_id uuid, p_plant_id uuid, p_kind text, p_subject_id uuid,
                                                 p_dedupe_key text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_alert public.alert_events;
begin
  if not (p_kind = any (app.owner_alert_kinds())) then
    raise exception 'VALIDATION_FAILED' using detail = 'kind: not an owner alert kind';
  end if;
  insert into public.alert_events as a (org_id, plant_id, kind, subject_id, recipients, dedupe_key)
  values (p_org_id, p_plant_id, p_kind, p_subject_id, '{}'::text[], p_dedupe_key)
  on conflict (kind, subject_id, shift_instance_id, dedupe_key) do nothing
  returning a.* into v_alert;
  if v_alert.id is null then
    return null;
  end if;
  -- Pending push ('{}') only if someone is left once the actor is removed. The actor is the SAME one push and
  -- the Alerts tab use (app.alert_actor: the subject row's entered_by / created_by), not the caller, so the
  -- three can never disagree. Same transaction: nobody sees the row before this settles.
  if not exists (select 1 from app.alert_recipient_users(v_alert)) then
    update public.alert_events set recipients = '{quiet}'::text[] where id = v_alert.id;
  end if;
  return v_alert.id;
end;
$$;
comment on function app.raise_owner_alert(uuid, uuid, text, uuid, text) is
  'Owner 2026-11-06 (C), 2026-11-09: writes an owner information alert (kind in app.owner_alert_kinds()). recipients ''{}'' (pending push) when app.alert_recipient_users finds at least one push owner other than the actor (app.alert_actor, from the subject row), else ''{quiet}''. Idempotent on (kind, subject, shift, dedupe_key). Returns the new alert id or null. Internal (called by RPCs after their own role checks).';

-- Legacy machine-down push helpers (20261105170949), superseded by public.get_pending_push_alerts /
-- app.pending_push_notifications and unused by the send-alerts Edge Function. They pre-date the actor rule,
-- so the service role may no longer call them (security review 2026-11-09); kept for the existing tests.
revoke execute on function app.pending_machine_down_alerts() from service_role;
revoke execute on function app.claim_machine_down_alerts() from service_role;
-- Security re-review L1: the public wrappers over the legacy helpers are definer functions, so the
-- service role could still reach the actor-blind path through them. send-alerts uses
-- claim_push_notifications / mark_push_alert_delivered only; close the wrappers too.
revoke execute on function public.get_pending_push_alerts() from service_role;
revoke execute on function public.claim_push_alerts() from service_role;
