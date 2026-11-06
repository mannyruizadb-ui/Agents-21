-- Push delivery for every alert kind (owner 2026-11-06) and the washer idle alarm (D).
--
-- alert_events
--   * new kinds: washer_idle, task_assigned, task_done, route_loaded (task and route rows come with
--     the load-out and task migrations);
--   * dedupe_key (text): the uniqueness is now (kind, subject_id, shift_instance_id, dedupe_key), so a
--     subject can alert more than once (a task reminder every 10 minutes; one washer_idle per idle
--     period = per finished cycle). Existing rows keep dedupe_key null: same behaviour as before.
--
-- Generic delivery (service role only), used by the send-alerts Edge Function:
--   app.alert_recipient_users(alert)  who receives an alert (per kind; replaced as kinds are added)
--   app.alert_payload(alert)          what the notification may show (per kind; jsonb)
--   app.pending_push_notifications()  one row per pending alert × recipient subscription
--   app.claim_push_notifications()    claims them (at most once, FOR UPDATE SKIP LOCKED)
--   public.get_pending_push_notifications() / public.claim_push_notifications(): PostgREST wrappers
--   mark_alert_delivered / mark_push_alert_delivered now accept every push kind.
-- Every recipient must still hold an active owner or manager membership of the alert's plant, an
-- active push subscription on that plant, and not be banned. Alerts older than 1 hour are not sent.
-- The machine-down-only claim_push_alerts / get_pending_push_alerts stay for the deployed function
-- (deprecated: switch to claim_push_notifications; both use the same claim marker, never double-send).
--
-- Lock-screen text (DECIDED): payloads carry no free text, except (later) a task's own text, which goes
-- only to the task's assignees and back to the owners who wrote it. Machine-down details, done notes
-- and names are never in a payload; reason codes and labels are preset data.
--
-- Washer idle (D; owner 2026-11-06: 15 minutes): app.generate_washer_idle_alerts() writes ONE
-- washer_idle alert per washer per idle period (dedupe_key = the finished cycle id) when, for an active
-- washer that is not down: its latest live cycle finished (started_at + formula cycle_minutes) at
-- least 15 minutes ago, no newer cycle started, its area has a shift running now, and the area's queue
-- has open work for that washer (assigned to it, or unassigned). Recipients: the plant's owners and the
-- managers on duty when it fired. Washers without a formula time never alarm.
--
-- Scheduling: the every-minute pg_cron job send-alerts now runs app.alert_tick(): the generators, then
-- app.dispatch_send_alerts() (which now looks at every pending push kind).

alter table public.alert_events
  add column dedupe_key text check (char_length(dedupe_key) between 1 and 100),
  drop constraint alert_events_kind_check,
  add constraint alert_events_kind_check check (kind in ('estimate_stale', 'device_offline', 'import_failed',
    'shift_generation_failed', 'machine_down', 'washer_idle', 'task_assigned', 'task_done', 'route_loaded')),
  drop constraint alert_events_kind_subject_id_shift_instance_id_key,
  add constraint alert_events_dedupe_key unique nulls not distinct (kind, subject_id, shift_instance_id, dedupe_key);
comment on column public.alert_events.dedupe_key is
  'Owner 2026-11-06: distinguishes repeated alerts of one subject (task reminder number; washer_idle = the finished cycle id). Null for one-per-subject kinds.';
comment on table public.alert_events is
  'Alerts for the notifier (service role only; RLS on, no client policies). Push kinds: machine_down (subject = machine_status_events.id), washer_idle (subject = machine, dedupe_key = finished cycle), task_assigned (subject = task, dedupe_key = reminder number), task_done (subject = task), route_loaded (subject = route_load_events.id). recipients ''{}'' = not yet delivered; ''{claimed}'' = being delivered. One row per (kind, subject, shift, dedupe_key).';

-- The pg_cron shift generator upserts its failure alert on the alert_events unique key: follow the new key.
CREATE OR REPLACE FUNCTION app.generate_all_shift_instances(p_days integer DEFAULT 7, p_from date DEFAULT NULL::date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_plant record;
  v_total int := 0;
begin
  for v_plant in select p.id, p.org_id from public.plants p order by p.id loop
    begin
      v_total := v_total + app.generate_shift_instances(v_plant.id, p_days, p_from);
    exception when others then
      raise warning 'generate_shift_instances failed for plant %: % (%)', v_plant.id, sqlerrm, sqlstate;
      insert into public.alert_events (org_id, plant_id, kind, subject_id, recipients)
      values (v_plant.org_id, v_plant.id, 'shift_generation_failed', v_plant.id, '{}')
      on conflict (kind, subject_id, shift_instance_id, dedupe_key) do update set sent_at = excluded.sent_at, recipients = '{}';
    end;
  end loop;
  return v_total;
end;
$function$;

create function app.push_alert_kinds()
returns text[] language sql immutable set search_path = '' as $$
  select array['machine_down', 'washer_idle', 'task_assigned', 'task_done', 'route_loaded'];
$$;
comment on function app.push_alert_kinds() is 'Owner 2026-11-06: alert_events kinds delivered by Web Push.';
revoke all on function app.push_alert_kinds() from public, anon, authenticated;
grant execute on function app.push_alert_kinds() to service_role;

-- Owners of a plant (active owner memberships of the plant or its org).
create function app.plant_owner_users(p_plant_id uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select distinct m.user_id from public.memberships m
    join public.plants p on p.id = p_plant_id and p.org_id = m.org_id
   where m.role = 'owner' and m.revoked_at is null and (m.plant_id is null or m.plant_id = p_plant_id);
$$;
comment on function app.plant_owner_users(uuid) is 'Owner 2026-11-06: user ids of the plant''s active owners (plant or org-wide). Internal.';
revoke all on function app.plant_owner_users(uuid) from public, anon, authenticated;
grant execute on function app.plant_owner_users(uuid) to service_role;

create function app.alert_recipient_users(p_alert public.alert_events)
returns setof uuid language plpgsql stable security definer set search_path = '' as $$
begin
  if p_alert.kind = 'machine_down' then
    return query
      select distinct m.user_id from public.memberships m
        join public.plants p on p.id = p_alert.plant_id and p.org_id = m.org_id
       where m.revoked_at is null and m.role in ('owner', 'manager') and m.notify_machine_down
         and (m.plant_id is null or m.plant_id = p_alert.plant_id);
  elsif p_alert.kind = 'washer_idle' then
    return query
      select u from app.plant_owner_users(p_alert.plant_id) u
      union
      select u from app.managers_on_duty(p_alert.plant_id, p_alert.sent_at) u;
  end if;
  -- Other kinds are added by their own migrations.
end;
$$;
comment on function app.alert_recipient_users(public.alert_events) is
  'Owner 2026-11-06: who receives a push alert. machine_down: owner/manager members with notify_machine_down; washer_idle: the plant''s owners + managers on duty when it fired. Internal.';
revoke all on function app.alert_recipient_users(public.alert_events) from public, anon, authenticated;
grant execute on function app.alert_recipient_users(public.alert_events) to service_role;

create function app.alert_payload(p_alert public.alert_events)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v jsonb;
begin
  if p_alert.kind = 'machine_down' then
    select pg_catalog.jsonb_build_object(
             'machine_id', m.id, 'machine_name', m.name, 'machine_kind', m.kind, 'area_name', ar.name,
             'reason_code', e.reason_code, 'reason_label_i18n', r.label_i18n, 'down_since', e.occurred_at,
             'still_down', app.machine_is_down_at(m.id, m.plant_id, pg_catalog.now()))
      into v
      from public.machine_status_events e
      join public.machines m on m.id = e.machine_id and m.plant_id = e.plant_id
      join public.areas ar on ar.id = m.area_id and ar.plant_id = m.plant_id
      left join public.machine_down_reasons r on r.plant_id = e.plant_id and r.code = e.reason_code
     where e.id = p_alert.subject_id and e.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'washer_idle' then
    select pg_catalog.jsonb_build_object(
             'machine_id', m.id, 'machine_name', m.name, 'area_name', ar.name,
             'idle_since', c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes),
             'still_idle', not exists (select 1 from public.washer_cycles w2
                                        where w2.machine_id = m.id and w2.plant_id = m.plant_id and w2.voided_at is null
                                          and (w2.started_at, w2.id) > (c.started_at, c.id)))
      into v
      from public.machines m
      join public.areas ar on ar.id = m.area_id and ar.plant_id = m.plant_id
      left join public.washer_cycles c on c.id::text = p_alert.dedupe_key and c.plant_id = m.plant_id
      left join public.wash_formulas f on f.id = c.wash_formula_id
     where m.id = p_alert.subject_id and m.plant_id = p_alert.plant_id;
  end if;
  return coalesce(v, '{}'::jsonb);
end;
$$;
comment on function app.alert_payload(public.alert_events) is
  'Owner 2026-11-06: what a push notification may show, per kind (jsonb; no free text except a task''s own text to its assignees/owners). machine_down: machine, area, reason_code + label, down_since, still_down. washer_idle: machine, area, idle_since, still_idle. Internal.';
revoke all on function app.alert_payload(public.alert_events) from public, anon, authenticated;
grant execute on function app.alert_payload(public.alert_events) to service_role;

create function app.pending_push_notifications()
returns table (
  alert_id        uuid,
  kind            text,
  alert_created   timestamptz,
  org_id          uuid,
  plant_id        uuid,
  plant_name      text,
  payload         jsonb,
  subscription_id uuid,
  user_id         uuid,
  language        text,
  endpoint        text,
  p256dh          text,
  auth            text)
language sql stable security definer set search_path = '' as $$
  select a.id, a.kind, a.sent_at, a.org_id, a.plant_id, p.name, app.alert_payload(a),
         s.id, s.user_id, pr.language, s.endpoint, s.p256dh, s.auth
    from public.alert_events a
    join public.plants p on p.id = a.plant_id and p.org_id = a.org_id
   cross join lateral app.alert_recipient_users(a) r(uid)
    join public.push_subscriptions s on s.user_id = r.uid and s.plant_id = a.plant_id and s.org_id = a.org_id and s.revoked_at is null
    join auth.users u on u.id = s.user_id and (u.banned_until is null or u.banned_until <= pg_catalog.now())
    left join public.profiles pr on pr.user_id = s.user_id
   where a.kind = any (app.push_alert_kinds())
     and a.recipients = '{}'
     and a.sent_at > pg_catalog.now() - interval '1 hour'
     and exists (
       select 1 from public.memberships mm
        where mm.user_id = s.user_id and mm.org_id = a.org_id
          and (mm.plant_id is null or mm.plant_id = a.plant_id)
          and mm.revoked_at is null and mm.role in ('owner', 'manager'))
   order by a.sent_at, a.id, s.id;
$$;
comment on function app.pending_push_notifications() is
  'Owner 2026-11-06 (service role only): undelivered push alerts of every push kind (≤ 1 h old) × their recipients'' active subscriptions on the alert''s plant (recipients must be active owner/manager members, not banned). Columns: alert_id, kind, alert_created, org_id, plant_id, plant_name, payload (jsonb, see app.alert_payload), subscription_id, user_id, language, endpoint, p256dh, auth.';
revoke all on function app.pending_push_notifications() from public, anon, authenticated;
grant execute on function app.pending_push_notifications() to service_role;

create function app.claim_push_notifications()
returns table (
  alert_id        uuid,
  kind            text,
  alert_created   timestamptz,
  org_id          uuid,
  plant_id        uuid,
  plant_name      text,
  payload         jsonb,
  subscription_id uuid,
  user_id         uuid,
  language        text,
  endpoint        text,
  p256dh          text,
  auth            text)
language plpgsql volatile security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_ids uuid[];
begin
  select coalesce(pg_catalog.array_agg(x.id), '{}') into v_ids
    from (select a.id from public.alert_events a
           where a.kind = any (app.push_alert_kinds()) and a.recipients = '{}'
             and a.id in (select p.alert_id from app.pending_push_notifications() p)
           order by a.sent_at, a.id
             for update skip locked) x;
  if pg_catalog.cardinality(v_ids) = 0 then
    return;
  end if;
  return query select p.* from app.pending_push_notifications() p where p.alert_id = any (v_ids);
  update public.alert_events a set recipients = '{claimed}' where a.id = any (v_ids);
end;
$$;
comment on function app.claim_push_notifications() is
  'Owner 2026-11-06 (service role only): atomically claims the pending push alerts of every kind that have recipients (FOR UPDATE SKIP LOCKED; recipients := ''{claimed}'') and returns their rows (shape of app.pending_push_notifications). At most once: record the result with app.mark_alert_delivered.';
revoke all on function app.claim_push_notifications() from public, anon, authenticated;
grant execute on function app.claim_push_notifications() to service_role;

create function public.get_pending_push_notifications()
returns table (alert_id uuid, kind text, alert_created timestamptz, org_id uuid, plant_id uuid, plant_name text,
               payload jsonb, subscription_id uuid, user_id uuid, language text, endpoint text, p256dh text, auth text)
language sql stable security definer set search_path = '' as $$
  select * from app.pending_push_notifications();
$$;
comment on function public.get_pending_push_notifications() is
  'Owner 2026-11-06 (SERVICE ROLE ONLY; send-alerts Edge Function via PostgREST): app.pending_push_notifications(). No client role may execute it.';
revoke all on function public.get_pending_push_notifications() from public, anon, authenticated;
grant execute on function public.get_pending_push_notifications() to service_role;

create function public.claim_push_notifications()
returns table (alert_id uuid, kind text, alert_created timestamptz, org_id uuid, plant_id uuid, plant_name text,
               payload jsonb, subscription_id uuid, user_id uuid, language text, endpoint text, p256dh text, auth text)
language sql volatile security definer set search_path = '' as $$
  select * from app.claim_push_notifications();
$$;
comment on function public.claim_push_notifications() is
  'Owner 2026-11-06 (SERVICE ROLE ONLY; send-alerts Edge Function via PostgREST): app.claim_push_notifications(). Claim, send, then mark_push_alert_delivered. No client role may execute it.';
revoke all on function public.claim_push_notifications() from public, anon, authenticated;
grant execute on function public.claim_push_notifications() to service_role;

create or replace function app.mark_alert_delivered(p_alert_id uuid, p_recipients text[])
returns boolean language plpgsql volatile security definer set search_path = '' as $$
declare
  v_n int;
begin
  if p_alert_id is null or p_recipients is null or pg_catalog.cardinality(p_recipients) = 0
     or pg_catalog.cardinality(p_recipients) > 1000
     or exists (select 1 from pg_catalog.unnest(p_recipients) r where r is null or pg_catalog.char_length(r) not between 1 and 200) then
    raise exception 'VALIDATION_FAILED' using detail = 'p_alert_id required; p_recipients: 1–1000 non-empty values (≤ 200 chars each)';
  end if;
  update public.alert_events a
     set recipients = p_recipients
   where a.id = p_alert_id and a.kind = any (app.push_alert_kinds()) and a.recipients in ('{}', '{claimed}');
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;
comment on function app.mark_alert_delivered(uuid, text[]) is
  'Owner 2026-11-04/06 (service role only): records the final recipients of a pending or claimed push alert of any push kind (subscription ids, or a marker such as ''none'' / ''stale''). True when it changed the alert; false when missing, not a push kind, or already delivered. Errors: VALIDATION_FAILED.';

-- ── D: washer idle alarm ──────────────────────────────────────────────────
create function app.generate_washer_idle_alerts()
returns int language plpgsql volatile security definer set search_path = '' as $$
declare
  v_n int;
begin
  insert into public.alert_events (org_id, plant_id, kind, subject_id, recipients, dedupe_key)
  select m.org_id, m.plant_id, 'washer_idle', m.id, '{}', c.id::text
    from public.machines m
    join lateral (
      select w.id, w.started_at, w.wash_formula_id from public.washer_cycles w
       where w.machine_id = m.id and w.plant_id = m.plant_id and w.voided_at is null
       order by w.started_at desc, w.id desc limit 1) c on true
    join public.wash_formulas f on f.id = c.wash_formula_id and f.cycle_minutes is not null
   where m.kind = 'washer' and m.active
     and c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes) <= pg_catalog.now() - interval '15 minutes'
     and not app.machine_is_down_at(m.id, m.plant_id, pg_catalog.now())
     and exists (select 1 from public.shift_instances si
                  where si.area_id = m.area_id and si.plant_id = m.plant_id and si.skipped_at is null
                    and si.starts_at <= pg_catalog.now() and si.ends_at > pg_catalog.now())
     and exists (select 1 from public.queue_items q
                  where q.area_id = m.area_id and q.plant_id = m.plant_id
                    and q.status in ('queued', 'in_progress')
                    and (q.assigned_machine_id = m.id or q.assigned_machine_id is null))
  on conflict (kind, subject_id, shift_instance_id, dedupe_key) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
comment on function app.generate_washer_idle_alerts() is
  'Owner 2026-11-06 (pg_cron via app.alert_tick; service role only): one washer_idle alert per washer per idle period (dedupe_key = the finished cycle) when an active, not-down washer finished its last cycle ≥ 15 min ago, nothing newer started, its area has a shift running and the queue has work for it. Returns alerts written.';
revoke all on function app.generate_washer_idle_alerts() from public, anon, authenticated;
grant execute on function app.generate_washer_idle_alerts() to service_role;

CREATE OR REPLACE FUNCTION app.dispatch_send_alerts()
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_url    text;
  v_secret text;
  v_id     bigint;
begin
  if not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net')
     or not exists (select 1 from pg_catalog.pg_namespace where nspname = 'vault') then
    return null;
  end if;
  select s.decrypted_secret into v_url from vault.decrypted_secrets s where s.name = 'send_alerts_url' limit 1;
  select s.decrypted_secret into v_secret from vault.decrypted_secrets s where s.name = 'send_alerts_secret' limit 1;
  if v_url is null or v_secret is null
     or not (v_url ~* '^https://[^[:space:][:cntrl:]]+$'
             or v_url ~* '^http://(localhost|127\.0\.0\.1|host\.docker\.internal|kong)(:[0-9]{1,5})?(/[^[:space:][:cntrl:]]*)?$') then
    return null;
  end if;
  if not exists (select 1 from app.pending_push_notifications()) then
    return null;
  end if;
  select net.http_post(
           url := v_url,
           body := pg_catalog.jsonb_build_object('source', 'pg_cron', 'kind', 'machine_down'),
           headers := pg_catalog.jsonb_build_object('Content-Type', 'application/json',
                                                    'Authorization', 'Bearer ' || v_secret),
           timeout_milliseconds := 10000)
    into v_id;
  return v_id;
exception when others then
  raise warning 'dispatch_send_alerts failed: % (%)', sqlerrm, sqlstate;
  return null;
end;
$function$;

create function app.alert_tick()
returns bigint language plpgsql volatile security definer set search_path = '' as $$
begin
  begin
    perform app.generate_washer_idle_alerts();
  exception when others then
    raise warning 'generate_washer_idle_alerts failed: % (%)', sqlerrm, sqlstate;
  end;
  return app.dispatch_send_alerts();
end;
$$;
comment on function app.alert_tick() is
  'Owner 2026-11-06 (pg_cron every minute; service role only): runs the alert generators (washer idle; task reminders once tasks exist), then app.dispatch_send_alerts(). A failing generator only warns.';
revoke all on function app.alert_tick() from public, anon, authenticated;
grant execute on function app.alert_tick() to service_role;

do $$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'send-alerts';
    perform cron.schedule('send-alerts', '* * * * *', 'select app.alert_tick()');
  else
    raise warning 'pg_cron is not available: schedule app.alert_tick() every minute manually';
  end if;
end;
$$;

-- ── Security re-review follow-ups (2026-11-06, notes 2 and 3) ─────────────
-- (2) A display reads only open queue items and items done during its area's current shift (the
--     non-owner rule), not the area's whole history.
drop policy queue_items_select on public.queue_items;
create policy queue_items_select on public.queue_items for select to authenticated
  using ((select app.has_role(plant_id, '{owner}'))
         or (((select app.has_role(plant_id, '{manager,lead,viewer}'))
              or ((select app.is_display(plant_id)) and area_id = (select (app.my_device()).area_id)))
             and (status in ('queued', 'in_progress')
                  or (status = 'done' and exists (
                        select 1 from public.shift_instances si
                         where si.area_id = queue_items.area_id and si.plant_id = queue_items.plant_id
                           and si.skipped_at is null and si.starts_at <= now() and si.ends_at > now()
                           and queue_items.completed_at >= si.starts_at and queue_items.completed_at < si.ends_at)))));

-- (3) managers_on_duty re-checks that the membership belongs to the assignment's org and plant.
create or replace function app.managers_on_duty(p_plant_id uuid, p_at timestamptz)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select distinct m.user_id
    from public.manager_shift_assignments a
    join public.memberships m on m.id = a.membership_id and m.role = 'manager' and m.revoked_at is null
                             and m.org_id = a.org_id and (m.plant_id is null or m.plant_id = a.plant_id)
    join public.shift_instances si on si.shift_id = a.shift_id and si.plant_id = a.plant_id
   where a.plant_id = p_plant_id and a.active
     and si.skipped_at is null and si.starts_at <= p_at and si.ends_at > p_at;
$$;
