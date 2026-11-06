-- Security review 2026-11-04 (push layer), M1: at-most-once delivery. Two overlapping send-alerts runs
-- could both read the same pending alerts and push twice. The sender now CLAIMS instead of reading:
--   app.claim_machine_down_alerts() / public.claim_push_alerts() (service role only)
--     locks the pending machine_down alerts that have at least one recipient (FOR UPDATE SKIP LOCKED,
--     so a concurrent run skips them), returns their rows in the same shape as
--     get_pending_push_alerts(), and sets their recipients to '{claimed}' in the same transaction.
--     A second claim returns nothing for them.
--   app.mark_alert_delivered / public.mark_push_alert_delivered then records the final recipients;
--     it now accepts a claimed alert as well as a pending one.
-- A run that crashes after claiming leaves the alert '{claimed}' (never sent twice; at most once).
-- Pending alerts without any recipient are not claimed (a subscription may still appear within the
-- hour). get_pending_push_alerts() stays (read-only; dispatch_send_alerts uses the app helper to
-- decide whether to invoke the function).

create function app.claim_machine_down_alerts()
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
language plpgsql volatile security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_ids uuid[];
begin
  select coalesce(pg_catalog.array_agg(x.id), '{}') into v_ids
    from (select a.id from public.alert_events a
           where a.kind = 'machine_down' and a.recipients = '{}'
             and a.id in (select p.alert_id from app.pending_machine_down_alerts() p)
           order by a.sent_at, a.id
             for update skip locked) x;
  if pg_catalog.cardinality(v_ids) = 0 then
    return;
  end if;
  -- Rows first (the pending view filters on recipients = '{}'), then mark them claimed.
  return query select p.* from app.pending_machine_down_alerts() p where p.alert_id = any (v_ids);
  update public.alert_events a set recipients = '{claimed}' where a.id = any (v_ids);
end;
$$;
comment on function app.claim_machine_down_alerts() is
  'Security review M1 (2026-11-04; service role only): atomically claims the pending machine_down alerts that have recipients (FOR UPDATE SKIP LOCKED; recipients := ''{claimed}'') and returns their rows in the shape of app.pending_machine_down_alerts() (never the free-text reason). A concurrent or later claim gets nothing for them. Record the final recipients with app.mark_alert_delivered.';
revoke all on function app.claim_machine_down_alerts() from public, anon, authenticated;
grant execute on function app.claim_machine_down_alerts() to service_role;

create function public.claim_push_alerts()
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
language sql volatile security definer set search_path = '' as $$
  select * from app.claim_machine_down_alerts();
$$;
comment on function public.claim_push_alerts() is
  'Security review M1 (2026-11-04; SERVICE ROLE ONLY, for the send-alerts Edge Function via PostgREST): app.claim_machine_down_alerts(). Claim, send, then mark_push_alert_delivered. No client role may execute it.';
revoke all on function public.claim_push_alerts() from public, anon, authenticated;
grant execute on function public.claim_push_alerts() to service_role;

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
   where a.id = p_alert_id and a.kind = 'machine_down' and a.recipients in ('{}', '{claimed}');
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;
comment on function app.mark_alert_delivered(uuid, text[]) is
  'Owner 2026-11-04 (service role only): records the final recipients of a pending or claimed (security M1) machine_down alert (subscription ids, or a marker such as ''none'' / ''stale''). Returns true when it changed the alert; false when it is missing, not machine_down, or already delivered (a retry never sends twice). Errors: VALIDATION_FAILED.';
