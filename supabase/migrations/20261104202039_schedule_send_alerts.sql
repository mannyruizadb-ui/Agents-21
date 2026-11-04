-- Every minute, pg_cron asks the send-alerts Edge Function (not in this migration; owned by the
-- edge engineer) to deliver pending machine-down Web Push alerts, via pg_net.
--
-- Configuration lives in Supabase Vault (never in code or migrations):
--   send_alerts_url     the Edge Function URL, e.g. https://<ref>.supabase.co/functions/v1/send-alerts
--   send_alerts_secret  a shared secret sent as "Authorization: Bearer <secret>"
-- Create them once per environment (SQL editor or CI):
--   select vault.create_secret('<url>', 'send_alerts_url');
--   select vault.create_secret('<secret>', 'send_alerts_secret');
-- app.dispatch_send_alerts() does NOTHING (returns null, no error) when pg_net or Vault is missing,
-- when either secret is missing, or when there is no pending alert; so the job costs one cheap query
-- per minute and never invokes the function needlessly. Errors are logged as warnings, never raised.
-- Guards: pg_net and pg_cron are created if available; without pg_cron the job is not scheduled
-- (warning) and must be added later. Both are available on Supabase cloud and the local image.

do $$
begin
  if exists (select 1 from pg_catalog.pg_available_extensions where name = 'pg_net') then
    begin
      create extension if not exists pg_net with schema extensions;
    exception when others then
      raise warning 'pg_net not created (%): send-alerts dispatch stays off', sqlerrm;
    end;
  else
    raise warning 'pg_net is not available: send-alerts dispatch stays off';
  end if;
end;
$$;

create function app.dispatch_send_alerts()
returns bigint language plpgsql volatile security definer set search_path = '' as $$
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
  if v_url is null or v_secret is null or v_url !~ '^https?://' then
    return null;
  end if;
  if not exists (select 1 from app.pending_machine_down_alerts()) then
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
$$;
comment on function app.dispatch_send_alerts() is
  'Owner 2026-11-04 (pg_cron every minute; postgres/service_role only): when pg_net, Vault secrets send_alerts_url + send_alerts_secret and at least one pending machine-down alert exist, POSTs {source, kind} to the send-alerts Edge Function with Authorization: Bearer <secret> via net.http_post and returns the pg_net request id. Otherwise returns null; never raises (warnings only).';
revoke all on function app.dispatch_send_alerts() from public, anon, authenticated;
grant execute on function app.dispatch_send_alerts() to service_role;

do $$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'send-alerts';
    perform cron.schedule('send-alerts', '* * * * *', 'select app.dispatch_send_alerts()');
  else
    raise warning 'pg_cron is not available: schedule app.dispatch_send_alerts() every minute manually';
  end if;
end;
$$;
