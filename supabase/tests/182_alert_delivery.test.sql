-- Machine-down alert delivery helpers (owner 2026-11-04): app.pending_machine_down_alerts,
-- app.mark_alert_delivered and their public service-role wrappers. Who receives, what is exposed,
-- and that no client role can call them.
begin;
\ir _fixtures.psql
select plan(16);

create function pg_temp.k() returns text language sql immutable as $$ select repeat('B', 86) || 'A' $$;
create function pg_temp.a() returns text language sql immutable as $$ select 'abcdefghij_-KLMNOPQRST' $$;
grant execute on function pg_temp.k(), pg_temp.a() to authenticated, anon;
insert into public.machines (id, org_id, plant_id, area_id, name, kind, active) values
  ('60000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 3', 'washer', true),
  ('60000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), 'Washer B', 'washer', true);

-- Subscriptions: owner (alerts on by default), manager (off), owner B; a lead and a revoked one by hand.
select is(array[
  pg_temp.run_as('owner', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://push.example/owner', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('owner', $$select public.save_push_subscription(pg_temp.id('plantA2'), 'https://push.example/owner-a2', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://push.example/manager', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('ownerB', $$select public.save_push_subscription(pg_temp.id('plantB'), 'https://push.example/ownerB', pg_temp.k(), pg_temp.a())$$),
  pg_temp.as_service($$insert into public.push_subscriptions (org_id, plant_id, user_id, endpoint, p256dh, auth) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('lead'), 'https://push.example/lead', pg_temp.k(), pg_temp.a())$$),
  pg_temp.as_service($$insert into public.push_subscriptions (org_id, plant_id, user_id, endpoint, p256dh, auth, revoked_at) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('owner'), 'https://push.example/old', pg_temp.k(), pg_temp.a(), now())$$)],
  '{1,1,1,1,1,1}', 'subscriptions set up');
update public.memberships set notify_machine_down = true where user_id = pg_temp.id('lead');   -- even if forced on, a lead never receives

select is(array[
  pg_temp.run_as('manager', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), 'Ana slipped near the drain', 'leaking')$$),
  pg_temp.run_as('ownerB', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000b1', 'down', gen_random_uuid(), p_reason_code => 'wont_start')$$)],
  '{1,1}', 'Washer 1 (plant A) and Washer B (plant B) go down');

select is((select array_agg(endpoint || ':' || machine_name || ':' || reason_code || ':' || still_down || ':' || coalesce(language, '-') order by endpoint)
             from app.pending_machine_down_alerts()),
  array['https://push.example/owner:Washer 1:leaking:true:en', 'https://push.example/ownerB:Washer B:wont_start:true:en'],
  'recipients: the owner''s plant A subscription only (manager off, lead never, revoked and other-plant subscriptions excluded); plant B to owner B');
select is((select array_agg(distinct (p256dh = pg_temp.k() and auth = pg_temp.a() and area_name = 'Washroom' and plant_name = 'Plant A')::text)
             from app.pending_machine_down_alerts() where plant_id = pg_temp.id('plantA')),
  array['true'], 'rows carry the keys, area and plant for the sender');
select is((select count(*)::int from pg_catalog.pg_proc p cross join lateral pg_catalog.pg_get_function_result(p.oid) r(res)
            where p.proname in ('pending_machine_down_alerts', 'get_pending_push_alerts') and (res ~ '\mreason text' or res ~ 'reason text,')), 0,
  'the free-text reason is never returned (reason_code only)');
select ok(position('Ana slipped' in (select coalesce(string_agg(x::text, ' '), '') from app.pending_machine_down_alerts() x)) = 0,
  'no row contains the free text');

-- The manager is turned on by the owner.
select is(pg_temp.run_as('owner', $$select public.set_alert_recipient((select id from public.memberships where user_id = pg_temp.id('manager')), true)$$),
  '1', 'the owner turns alerts on for the manager');
select is((select count(*)::int from app.pending_machine_down_alerts() where plant_id = pg_temp.id('plantA')), 2, 'now the manager''s subscription is included');
update auth.users set banned_until = now() + interval '1 day' where id = pg_temp.id('manager');
select is((select count(*)::int from app.pending_machine_down_alerts() where plant_id = pg_temp.id('plantA')), 1, 'a banned (deactivated) user is skipped');
update auth.users set banned_until = null where id = pg_temp.id('manager');

-- ══ Client roles cannot call any of it ═══════════════════════════════════
select is(array[
  has_function_privilege('authenticated', 'app.pending_machine_down_alerts()', 'execute'),
  has_function_privilege('authenticated', 'app.mark_alert_delivered(uuid,text[])', 'execute'),
  has_function_privilege('authenticated', 'public.get_pending_push_alerts()', 'execute'),
  has_function_privilege('authenticated', 'public.mark_push_alert_delivered(uuid,text[])', 'execute'),
  has_function_privilege('anon', 'public.get_pending_push_alerts()', 'execute'),
  has_function_privilege('service_role', 'public.get_pending_push_alerts()', 'execute'),
  has_function_privilege('service_role', 'public.mark_push_alert_delivered(uuid,text[])', 'execute')],
  array[false, false, false, false, false, true, true], 'service_role only');
select is(array[pg_temp.run_as('owner', $$select * from public.get_pending_push_alerts()$$),
                pg_temp.run_as('manager', $$select public.mark_push_alert_delivered(gen_random_uuid(), '{x}')$$),
                pg_temp.run_as('anon', $$select * from public.get_pending_push_alerts()$$)],
  '{42501,42501,42501}', 'owner, manager and anon are refused (no other users'' keys, no reasons)');

-- ══ mark_alert_delivered ═════════════════════════════════════════════════
select set_config('test.alert', (select alert_id::text from app.pending_machine_down_alerts() where plant_id = pg_temp.id('plantA') limit 1), true);
select is(array[
  pg_temp.as_service($$select app.mark_alert_delivered(current_setting('test.alert')::uuid, '{}')$$),
  pg_temp.as_service($$select app.mark_alert_delivered(current_setting('test.alert')::uuid, null)$$),
  pg_temp.as_service($$select app.mark_alert_delivered(current_setting('test.alert')::uuid, array[''])$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}', 'recipients must be a non-empty list of non-empty values');
select is(array[public.mark_push_alert_delivered(current_setting('test.alert')::uuid, array['sub-1', 'sub-2']),
                public.mark_push_alert_delivered(current_setting('test.alert')::uuid, array['sub-1'])],
  array[true, false], 'delivered once; a retry changes nothing');
select is((select recipients from public.alert_events where id = current_setting('test.alert')::uuid), array['sub-1', 'sub-2'], 'recipients recorded');
select is((select count(*)::int from public.get_pending_push_alerts() where plant_id = pg_temp.id('plantA')), 0, 'a delivered alert is no longer pending');

-- Older than 1 hour: no longer pending.
update public.alert_events set sent_at = now() - interval '61 minutes' where plant_id = pg_temp.id('plantB');
select is((select count(*)::int from app.pending_machine_down_alerts()), 0, 'alerts older than 1 hour are not sent');

select * from finish();
rollback;
