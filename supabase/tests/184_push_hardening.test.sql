-- Security review 2026-11-04 (push layer BLOCK) fixes: H1 audit_log never holds push endpoints or keys.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(4);

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

select * from finish();
rollback;
