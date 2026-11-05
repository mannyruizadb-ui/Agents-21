-- Security review 2026-11-04 (push layer), L1 + L2.
--
-- L2  app.dispatch_send_alerts() sends the bearer secret only over https. Plain http is allowed only
--     for local development hosts: localhost, 127.0.0.1, host.docker.internal and kong (the local
--     Supabase gateway). Any other URL in Vault → nothing is sent (null, no error).
-- L1  Revoking USAGE on schema net and its table/function grants from anon/authenticated is NOT
--     possible from a migration: the net objects are owned and granted by supabase_admin (PUBLIC also
--     holds USAGE on the schema and all privileges on net.http_request_queue / net._http_response),
--     and the migration role (postgres) is not a superuser, so REVOKE only warns "no privileges could
--     be revoked". The block below tries anyway (harmless; effective if run by a superuser) and logs
--     the result. Mitigation in place: PostgREST exposes only the public and graphql_public schemas
--     (supabase/config.toml [api].schemas; cloud default), so clients cannot call net.* or read the
--     queue through the API, and the only SQL path to net.http_post is app.dispatch_send_alerts
--     (service role / pg_cron). Follow-up: ask Supabase (or use the dashboard as supabase_admin) to
--     revoke these grants in the cloud; tracked in the HANDOFF.

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
$function$;

do $$
begin
  if exists (select 1 from pg_catalog.pg_namespace where nspname = 'net') then
    begin
      execute 'revoke usage on schema net from anon, authenticated';
      execute 'revoke all on all tables in schema net from anon, authenticated';
      execute 'revoke all on all functions in schema net from anon, authenticated';
    exception when others then
      raise warning 'net grants not revoked (%): see the migration header (L1)', sqlerrm;
    end;
    if pg_catalog.has_schema_privilege('authenticated', 'net', 'usage') then
      raise warning 'L1: authenticated still has USAGE on schema net (granted by supabase_admin/PUBLIC); not exposed through the API';
    end if;
  end if;
end;
$$;

comment on function app.dispatch_send_alerts() is
  'Owner 2026-11-04 (pg_cron every minute; postgres/service_role only): when pg_net, Vault secrets send_alerts_url + send_alerts_secret and at least one pending machine-down alert exist, POSTs {source, kind} to the send-alerts Edge Function with Authorization: Bearer <secret> via net.http_post and returns the pg_net request id. The URL must be https (http only for localhost, 127.0.0.1, host.docker.internal or kong: security review L2). Otherwise returns null; never raises (warnings only).';
