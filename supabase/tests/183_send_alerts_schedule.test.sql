-- send-alerts scheduling (owner 2026-11-04): pg_cron job every minute → app.dispatch_send_alerts(),
-- which calls the Edge Function through pg_net only when Vault holds the URL + secret and an alert
-- is pending; otherwise it does nothing and never errors.
begin;
\ir _fixtures.psql
select plan(10);

create function pg_temp.k() returns text language sql immutable as $$ select repeat('B', 86) || 'A' $$;
create function pg_temp.a() returns text language sql immutable as $$ select 'abcdefghij_-KLMNOPQRST' $$;
grant execute on function pg_temp.k(), pg_temp.a() to authenticated, anon;
create function pg_temp.queued() returns int language sql stable as $$
  select count(*)::int from net.http_request_queue where url like 'https://edge.example/%';
$$;

select ok(exists (select 1 from pg_extension where extname = 'pg_net'), 'pg_net is installed (local image)');
select is((select array[schedule, command] from cron.job where jobname = 'send-alerts'),
  array['* * * * *', 'select app.dispatch_send_alerts()'], 'pg_cron runs app.dispatch_send_alerts() every minute');
select is(array[has_function_privilege('authenticated', 'app.dispatch_send_alerts()', 'execute'),
                has_function_privilege('anon', 'app.dispatch_send_alerts()', 'execute')],
  array[false, false], 'clients cannot trigger the dispatch');

-- A pending alert: the owner subscribed, Washer 1 goes down.
select is(array[
  pg_temp.run_as('owner', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/owner', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), p_reason_code => 'water_pump')$$)],
  '{1,1}', 'a pending machine-down alert with one recipient');

-- No Vault secrets yet (a freshly reset database has none; postgres cannot edit vault.secrets).
select is(app.dispatch_send_alerts(), null::bigint, 'no Vault secrets: nothing is sent, no error');
select is(pg_temp.queued(), 0, 'no HTTP request queued');

select vault.create_secret('https://edge.example/functions/v1/send-alerts', 'send_alerts_url');
select is(app.dispatch_send_alerts(), null::bigint, 'only the URL: still nothing');
select vault.create_secret('s3cr3t-value', 'send_alerts_secret');
select ok(app.dispatch_send_alerts() is not null, 'URL + secret + a pending alert: one request id');
select is((select array[method::text, url, headers ->> 'Authorization'] from net.http_request_queue where url like 'https://edge.example/%'),
  array['POST', 'https://edge.example/functions/v1/send-alerts', 'Bearer s3cr3t-value'], 'POST to the Edge Function with the bearer secret');

-- Nothing pending (delivered): no call.
update public.alert_events set recipients = '{done}' where kind = 'machine_down';
select is(app.dispatch_send_alerts(), null::bigint, 'nothing pending: the function is not invoked');

select * from finish();
rollback;
