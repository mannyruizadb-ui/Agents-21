-- Web Push subscriptions (owner 2026-11-04): push_subscriptions, save_push_subscription,
-- remove_push_subscription. Owner/manager only, own rows only, keys never readable by clients.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(19);

-- A valid key pair (p256dh: 65 bytes → 87 base64url chars; auth: 16 bytes → 22 chars).
create function pg_temp.k() returns text language sql immutable as $$ select repeat('B', 86) || 'A' $$;
create function pg_temp.a() returns text language sql immutable as $$ select 'abcdefghij_-KLMNOPQRST' $$;
grant execute on function pg_temp.k(), pg_temp.a() to authenticated, anon;

select is(pg_temp.writes($$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/' || gen_random_uuid(), pg_temp.k(), pg_temp.a(), 'iPhone Safari')$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'save_push_subscription: owner/manager only (lead, viewer, display, other tenant: NOT_AUTHORIZED; anon: no EXECUTE)');
select is(array[
  pg_temp.run_as('ownerB', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/x1', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('ownerB', $$select public.save_push_subscription(gen_random_uuid(), 'https://fcm.googleapis.com/fcm/send/x2', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA2'), 'https://fcm.googleapis.com/fcm/send/x3', pg_temp.k(), pg_temp.a())$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}', 'no oracle: another tenant''s, a missing, and another plant''s plant look the same');
select is(array[
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'http://push.example/a', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/' || repeat('a', 1000), pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/a b', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), null, pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/b', 'short', pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/b', repeat('+', 87), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/b', pg_temp.k(), repeat('a', 33))$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/b', pg_temp.k(), pg_temp.a(), repeat('u', 301))$$)],
  array['VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED'],
  'rejects: http, > 1000 chars, whitespace, no endpoint, short p256dh, non-base64url p256dh, long auth, user_agent > 300 (hosts: see 184)');

-- ══ Own rows only, no keys ═══════════════════════════════════════════════
select is(pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/shared', pg_temp.k(), pg_temp.a(), 'Tablet')$$),
  '1', 'the manager subscribes a tablet');
select is(array[pg_temp.run_as('owner', $$select id from public.push_subscriptions$$, true),
                pg_temp.run_as('manager', $$select id from public.push_subscriptions$$, true),
                pg_temp.run_as('lead', $$select id from public.push_subscriptions$$, true),
                pg_temp.run_as('ownerB', $$select id from public.push_subscriptions$$, true),
                pg_temp.run_as('anon', $$select id from public.push_subscriptions$$, true)],
  '{1,2,0,0,42501}', 'each user reads only their own subscriptions; anon nothing');
select is(array[pg_temp.run_as('owner', $$select p256dh from public.push_subscriptions$$),
                pg_temp.run_as('manager', $$select auth from public.push_subscriptions$$),
                pg_temp.run_as('manager', $$select * from public.push_subscriptions$$)],
  '{42501,42501,42501}', 'the keys are never readable by clients (not even their own)');
select is(array[has_column_privilege('authenticated', 'public.push_subscriptions', 'p256dh', 'SELECT'),
                has_column_privilege('authenticated', 'public.push_subscriptions', 'auth', 'SELECT'),
                has_table_privilege('authenticated', 'public.push_subscriptions', 'INSERT'),
                has_table_privilege('authenticated', 'public.push_subscriptions', 'UPDATE'),
                has_table_privilege('authenticated', 'public.push_subscriptions', 'MAINTAIN'),
                has_any_column_privilege('anon', 'public.push_subscriptions', 'SELECT')],
  array[false, false, false, false, false, false], 'grants: no key columns, no direct writes, no MAINTAIN, nothing for anon');
select is(pg_temp.run_as('owner', $$insert into public.push_subscriptions (org_id, plant_id, user_id, endpoint, p256dh, auth) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('owner'), 'https://fcm.googleapis.com/fcm/send/d', pg_temp.k(), pg_temp.a())$$),
  '42501', 'no direct insert');

-- ══ Rebinding and removal ════════════════════════════════════════════════
select is(pg_temp.run_as('owner', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/shared', pg_temp.k(), pg_temp.a(), 'Tablet')$$),
  '1', 'the owner signs in on the same tablet and subscribes');
select is((select array[count(*)::text, min(user_id::text)] from public.push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/shared'),
  array['1', pg_temp.id('owner')::text], 'one row per endpoint, rebound to the owner');
select is(pg_temp.run_as('manager', $$select 1 from public.push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/shared'$$, true),
  '0', 'the manager no longer has that device');
select is(array[
  pg_temp.val_as('manager', $$select public.remove_push_subscription('https://fcm.googleapis.com/fcm/send/shared')::text$$),
  pg_temp.val_as('manager', $$select public.remove_push_subscription('https://fcm.googleapis.com/fcm/send/nope')::text$$),
  pg_temp.val_as('owner', $$select public.remove_push_subscription('https://fcm.googleapis.com/fcm/send/shared')::text$$),
  pg_temp.val_as('owner', $$select public.remove_push_subscription('https://fcm.googleapis.com/fcm/send/shared')::text$$)],
  array['false', 'false', 'true', 'false'],
  'remove: someone else''s or unknown endpoint → false (same answer); own → true; again → false');
select ok((select revoked_at is not null from public.push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/shared'),
  'removed = revoked (never deleted)');
select is(pg_temp.run_as('anon', $$select public.remove_push_subscription('https://fcm.googleapis.com/fcm/send/shared')$$), '42501', 'anon cannot call remove');
select is(pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/shared', pg_temp.k(), pg_temp.a())$$),
  '1', 'subscribing again …');
select is((select array[(revoked_at is null)::text, user_id::text, user_agent] from public.push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/shared'),
  array['true', pg_temp.id('manager')::text, null], '… un-revokes it and rebinds it to the caller');

-- ══ Table CHECKs (any write path) ════════════════════════════════════════
select is(array[
  pg_temp.as_service($$insert into public.push_subscriptions (org_id, plant_id, user_id, endpoint, p256dh, auth) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('owner'), 'ftp://x', pg_temp.k(), pg_temp.a())$$),
  pg_temp.as_service($$insert into public.push_subscriptions (org_id, plant_id, user_id, endpoint, p256dh, auth) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('owner'), 'https://fcm.googleapis.com/fcm/send/c', 'x', pg_temp.a())$$),
  pg_temp.as_service($$insert into public.push_subscriptions (org_id, plant_id, user_id, endpoint, p256dh, auth) values (pg_temp.id('orgB'), pg_temp.id('plantA'), pg_temp.id('owner'), 'https://fcm.googleapis.com/fcm/send/c', pg_temp.k(), pg_temp.a())$$)],
  '{23514,23514,23503}', 'CHECKs: https endpoint, key format; composite FK: plant must belong to the org');
select is((select count(*)::int from public.audit_log where entity = 'push_subscriptions' and plant_id = pg_temp.id('plantA')) > 0, true,
  'subscription changes are audited');
select is((select count(*)::int from public.push_subscriptions where plant_id = pg_temp.id('plantA') and user_id = pg_temp.id('owner')), 1,
  'the owner keeps the subscription from the role matrix');

select * from finish();
rollback;
