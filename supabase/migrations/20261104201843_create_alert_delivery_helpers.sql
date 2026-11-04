-- Delivery helpers for the send-alerts Edge Function (service role only), machine-down Web Push.
--
-- app.pending_machine_down_alerts(): one row per (alert × recipient subscription) for alert_events of
--   kind machine_down that are not yet delivered (recipients = '{}') and at most 1 hour old. Recipients
--   = active (non-revoked) push subscriptions on the alert's plant whose user has an active owner or
--   manager membership on that plant (or org-wide) with notify_machine_down = true, and is not banned.
--   It returns the preset reason_code (translated on the device) but NEVER the free-text reason: the
--   lock screen must not show free text. still_down = the machine has not been marked up since, so
--   the sender can skip stale alerts (and mark them delivered).
-- app.mark_alert_delivered(alert_id, recipients): records delivery (recipients = the subscription ids
--   or a marker such as 'none'), so a retry never sends twice. Only pending machine_down alerts change.
--
-- PostgREST exposes only the public schema, so the Edge Function calls the public wrappers
-- get_pending_push_alerts() / mark_push_alert_delivered(); a direct DB connection may call the app
-- functions. All four are executable by service_role only.

create function app.pending_machine_down_alerts()
returns table (
  alert_id        uuid,
  alert_created   timestamptz,       -- alert_events.sent_at (written when the machine went down)
  org_id          uuid,
  plant_id        uuid,
  plant_name      text,
  machine_id      uuid,
  machine_name    text,
  machine_kind    app.machine_kind,
  area_name       text,
  reason_code     app.machine_down_reason,   -- preset code only, never the free text
  down_since      timestamptz,
  still_down      boolean,
  subscription_id uuid,
  user_id         uuid,
  language        text,              -- the recipient's profile language (for the message text)
  endpoint        text,
  p256dh          text,
  auth            text)
language sql stable security definer set search_path = '' as $$
  select a.id, a.sent_at, a.org_id, a.plant_id, p.name, m.id, m.name, m.kind, ar.name, e.reason_code, e.occurred_at,
         app.machine_is_down_at(m.id, m.plant_id, pg_catalog.now()),
         s.id, s.user_id, pr.language, s.endpoint, s.p256dh, s.auth
    from public.alert_events a
    join public.plants p on p.id = a.plant_id and p.org_id = a.org_id
    join public.machine_status_events e on e.id = a.subject_id and e.plant_id = a.plant_id and e.status = 'down'
    join public.machines m on m.id = e.machine_id and m.plant_id = e.plant_id
    join public.areas ar on ar.id = m.area_id and ar.plant_id = m.plant_id
    join public.push_subscriptions s on s.plant_id = a.plant_id and s.org_id = a.org_id and s.revoked_at is null
    join auth.users u on u.id = s.user_id and (u.banned_until is null or u.banned_until <= pg_catalog.now())
    left join public.profiles pr on pr.user_id = s.user_id
   where a.kind = 'machine_down'
     and a.recipients = '{}'
     and a.sent_at > pg_catalog.now() - interval '1 hour'
     and exists (
       select 1 from public.memberships mm
        where mm.user_id = s.user_id and mm.org_id = a.org_id
          and (mm.plant_id = a.plant_id or mm.plant_id is null)
          and mm.revoked_at is null and mm.role in ('owner', 'manager') and mm.notify_machine_down)
   order by a.sent_at, a.id, s.id;
$$;
comment on function app.pending_machine_down_alerts() is
  'Owner 2026-11-04 (service role only): undelivered machine_down alerts (recipients ''{}'', ≤ 1 h old) × the active push subscriptions of their plant''s owner/manager members with notify_machine_down (not banned). Columns: alert_id, alert_created, org_id, plant_id, plant_name, machine_id, machine_name, machine_kind, area_name, reason_code (never the free text), down_since, still_down, subscription_id, user_id, language, endpoint, p256dh, auth.';
revoke all on function app.pending_machine_down_alerts() from public, anon, authenticated;
grant execute on function app.pending_machine_down_alerts() to service_role;

create function app.mark_alert_delivered(p_alert_id uuid, p_recipients text[])
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
   where a.id = p_alert_id and a.kind = 'machine_down' and a.recipients = '{}';
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;
comment on function app.mark_alert_delivered(uuid, text[]) is
  'Owner 2026-11-04 (service role only): records delivery of a pending machine_down alert (recipients = subscription ids, or a marker such as ''none'' / ''stale''). Returns true when it changed a pending alert; false when the alert is missing, not machine_down, or already delivered (so a retry never sends twice). Errors: VALIDATION_FAILED.';
revoke all on function app.mark_alert_delivered(uuid, text[]) from public, anon, authenticated;
grant execute on function app.mark_alert_delivered(uuid, text[]) to service_role;

-- ── public wrappers for the Edge Function (PostgREST, service role key) ───
create function public.get_pending_push_alerts()
returns table (
  alert_id        uuid,
  alert_created   timestamptz,
  org_id          uuid,
  plant_id        uuid,
  plant_name      text,
  machine_id      uuid,
  machine_name    text,
  machine_kind    app.machine_kind,
  area_name       text,
  reason_code     app.machine_down_reason,
  down_since      timestamptz,
  still_down      boolean,
  subscription_id uuid,
  user_id         uuid,
  language        text,
  endpoint        text,
  p256dh          text,
  auth            text)
language sql stable security definer set search_path = '' as $$
  select * from app.pending_machine_down_alerts();
$$;
comment on function public.get_pending_push_alerts() is
  'Owner 2026-11-04 (SERVICE ROLE ONLY; for the send-alerts Edge Function via PostgREST): same rows as app.pending_machine_down_alerts(). No client role may execute it.';
revoke all on function public.get_pending_push_alerts() from public, anon, authenticated;
grant execute on function public.get_pending_push_alerts() to service_role;

create function public.mark_push_alert_delivered(p_alert_id uuid, p_recipients text[])
returns boolean language sql volatile security definer set search_path = '' as $$
  select app.mark_alert_delivered(p_alert_id, p_recipients);
$$;
comment on function public.mark_push_alert_delivered(uuid, text[]) is
  'Owner 2026-11-04 (SERVICE ROLE ONLY; for the send-alerts Edge Function via PostgREST): app.mark_alert_delivered. No client role may execute it. Errors: VALIDATION_FAILED.';
revoke all on function public.mark_push_alert_delivered(uuid, text[]) from public, anon, authenticated;
grant execute on function public.mark_push_alert_delivered(uuid, text[]) to service_role;
