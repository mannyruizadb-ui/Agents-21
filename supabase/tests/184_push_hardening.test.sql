-- Security review 2026-11-04 (push layer BLOCK) fixes: H1 audit_log never holds push endpoints or keys;
-- M2 allow-listed push hosts and at most 5 active subscriptions per user; M3 no rebind of another
-- user's endpoint without its keys; M1 at-most-once delivery (claim_push_alerts).
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(31);

create function pg_temp.k() returns text language sql immutable as $$ select repeat('B', 86) || 'A' $$;
create function pg_temp.k2() returns text language sql immutable as $$ select repeat('C', 86) || 'A' $$;
create function pg_temp.a() returns text language sql immutable as $$ select 'abcdefghij_-KLMNOPQRST' $$;
grant execute on function pg_temp.k(), pg_temp.k2(), pg_temp.a() to authenticated, anon;

-- ══ H1: audit_log has no endpoint / keys ═════════════════════════════════
select is(array[
  pg_temp.run_as('owner', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/owner-secret-token', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('owner', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/owner-secret-token', pg_temp.k2(), pg_temp.a())$$),
  pg_temp.run_as('owner', $$select public.remove_push_subscription('https://fcm.googleapis.com/fcm/send/owner-secret-token')$$)],
  '{1,1,1}', 'subscribe, rotate keys, remove (three audited changes)');
select is(pg_temp.val_as('manager', $$select count(*)::text from public.audit_log where entity = 'push_subscriptions'$$),
  '3', 'the manager can read the push_subscriptions audit rows …');
select is(pg_temp.val_as('manager', $$select count(*)::text from public.audit_log where entity = 'push_subscriptions'
                                        and (coalesce(before, '{}') ?| array['endpoint', 'p256dh', 'auth'] or after ?| array['endpoint', 'p256dh', 'auth']
                                             or (coalesce(before, '{}')::text || after::text) ~ '(owner-secret-token|BBBBBBBB|CCCCCCCC|abcdefghij)')$$),
  '0', '… but none holds the endpoint, p256dh or auth (before or after)');
select is(pg_temp.val_as('manager', $$select string_agg(distinct after ->> 'endpoint_host', ',') from public.audit_log where entity = 'push_subscriptions'$$),
  'fcm.googleapis.com', 'only the push service host is kept');

-- ══ M2: allow-listed push hosts ══════════════════════════════════════════
select is(array[
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/m1', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://updates.push.services.mozilla.com/wpush/v2/m2', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://web.push.apple.com/QF3x-m3', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://wns2-bl2p.notify.windows.com/w/?token=m4', pg_temp.k(), pg_temp.a())$$)],
  '{1,1,1,1}', 'accepted: FCM, Mozilla, Apple (*.push.apple.com), Windows (*.notify.windows.com)');
select is(array[
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://attacker.example/push', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com.attacker.example/x', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://push.apple.com.evil.example/x', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://push.apple.com/x', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com:8443/x', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://user@fcm.googleapis.com/x', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'http://fcm.googleapis.com/x', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://evilnotify.windows.com/x', pg_temp.k(), pg_temp.a())$$)],
  array['VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED'],
  'rejected: other hosts, look-alike suffixes, the bare apple domain, ports, userinfo, http, a non-subdomain of notify.windows.com');
select is(pg_temp.as_service($$insert into public.push_subscriptions (org_id, plant_id, user_id, endpoint, p256dh, auth) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('owner'), 'https://attacker.example/push', pg_temp.k(), pg_temp.a())$$),
  '23514', 'the CHECK constraint enforces the same allow-list on any write path');

-- ══ M2: at most 5 active subscriptions per user (oldest revoked) ═════════
select is(pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/m5', pg_temp.k(), pg_temp.a())$$),
  '1', 'a fifth subscription');
select is((select count(*)::int from public.push_subscriptions where user_id = pg_temp.id('manager') and revoked_at is null), 5, 'five active');
select is(pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/m6', pg_temp.k(), pg_temp.a())$$),
  '1', 'a sixth device subscribes (never refused)');
select is((select array[count(*) filter (where revoked_at is null)::text,
                        string_agg(endpoint, ',') filter (where revoked_at is not null)]
             from public.push_subscriptions where user_id = pg_temp.id('manager')),
  array['5', 'https://fcm.googleapis.com/fcm/send/m1'], 'still five active: the least recently saved (m1) was revoked');
select is(pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://updates.push.services.mozilla.com/wpush/v2/m2', pg_temp.k(), pg_temp.a())$$),
  '1', 're-saving m2 makes it the most recent …');
select is(pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/m7', pg_temp.k(), pg_temp.a())$$),
  '1', '… so the next new device revokes m3, not m2');
select is((select array_agg(right(endpoint, 2) order by endpoint) from public.push_subscriptions where user_id = pg_temp.id('manager') and revoked_at is not null),
  array['m1', 'm3'], 'revoked: m1 and m3');

-- ══ M3: no rebind of another user's endpoint without its keys ════════════
select is(pg_temp.run_as('owner', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/m5', pg_temp.k2(), pg_temp.a())$$),
  '1', 'attack: the owner sends the manager''s endpoint with other keys … (same response, no error)');
select is((select array[user_id::text, (p256dh = pg_temp.k())::text, (revoked_at is null)::text]::text
             from public.push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/m5'),
  (select array[pg_temp.id('manager')::text, 'true', 'true']::text), '… and nothing changed: still the manager''s, same keys');
select is(pg_temp.run_as('ownerB', $$select public.save_push_subscription(pg_temp.id('plantB'), 'https://fcm.googleapis.com/fcm/send/m5', pg_temp.k2(), pg_temp.a())$$),
  '1', 'another tenant gets the same response');
select is((select org_id from public.push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/m5'), pg_temp.id('orgA'),
  'and cannot move it to their org');
select is(pg_temp.run_as('owner', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/m5', pg_temp.k(), pg_temp.a())$$),
  '1', 'the same browser (matching keys) under another account …');
select is((select user_id from public.push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/m5'), pg_temp.id('owner'),
  '… is rebound to that account');
select is(pg_temp.run_as('owner', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/m5', pg_temp.k2(), pg_temp.a())$$),
  '1', 'the owner rotates the keys of their own endpoint');
select is((select p256dh = pg_temp.k2() from public.push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/m5'), true, 'own keys rotate');

-- ══ M1: claim, then mark (at most once) ══════════════════════════════════
select is(pg_temp.run_as('owner', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), 'Ana: secret note', 'leaking')$$),
  '1', 'Washer 1 goes down: one pending alert for the owner''s subscription');
select set_config('test.claim1', (select coalesce(string_agg(alert_id::text || '/' || subscription_id::text, ','), '') from public.claim_push_alerts()), true);
select ok(current_setting('test.claim1') <> '', 'the first claim gets the rows');
select is((select count(*)::int from public.claim_push_alerts()), 0, 'a second claim gets nothing (already claimed)');
select is((select recipients from public.alert_events where kind = 'machine_down' and plant_id = pg_temp.id('plantA')), array['claimed'],
  'the alert is marked claimed in the same transaction');
select is((select count(*)::int from public.get_pending_push_alerts() where plant_id = pg_temp.id('plantA')), 0, 'and is no longer pending');
select is(array[public.mark_push_alert_delivered(split_part(current_setting('test.claim1'), '/', 1)::uuid, array[split_part(split_part(current_setting('test.claim1'), ',', 1), '/', 2)]),
                public.mark_push_alert_delivered(split_part(current_setting('test.claim1'), '/', 1)::uuid, array['again'])],
  array[true, false], 'mark records the final recipients once; a retry changes nothing');
select is(array[has_function_privilege('authenticated', 'public.claim_push_alerts()', 'execute'),
                has_function_privilege('anon', 'public.claim_push_alerts()', 'execute'),
                has_function_privilege('authenticated', 'app.claim_machine_down_alerts()', 'execute'),
                has_function_privilege('service_role', 'public.claim_push_alerts()', 'execute')],
  array[false, false, false, true], 'claim: service_role only');
select is(pg_temp.run_as('owner', $$select * from public.claim_push_alerts()$$), '42501', 'the owner cannot claim (or read keys)');
select is((select count(*)::int from pg_proc p where p.proname in ('claim_push_alerts', 'claim_machine_down_alerts')
             and pg_get_function_result(p.oid) ~ '(\(|, )reason text'), 0, 'claimed rows never carry the free-text reason');

select * from finish();
rollback;
