-- Sign-in lockout (owner-approved 2026-11-06; 20261107010613): sign_in_lockouts (service role only),
-- the sign_in_* RPCs (service role only), lock / unlock windows, the IP limit, no oracle for unknown
-- logins, and the account_locked owner alert. Statements run directly here have service-role semantics.
begin;
\ir _fixtures.psql
select plan(38);

update auth.users set email = 'denise@accounts.adbheadquarters.com' where id = pg_temp.id('manager');
insert into public.memberships (user_id, org_id, plant_id, role) values (pg_temp.id('ownerP'), pg_temp.id('orgA'), pg_temp.id('plantA'), 'owner');
create function pg_temp.mid(p_user text) returns uuid language sql stable security definer as $$
  select id from public.memberships where user_id = pg_temp.id(p_user) and revoked_at is null order by created_at, id limit 1;
$$;
grant execute on function pg_temp.mid(text) to authenticated, anon;
create function pg_temp.lk(p text) returns public.sign_in_lockouts language sql as $$
  select * from public.sign_in_lockouts where key_hash = app.sign_in_key('login', p);
$$;
-- n failed attempts (begin + failed) for a login from an IP; returns the last failed() result as text.
create function pg_temp.fail(p_login text, n int, p_ip text default '198.51.100.7') returns text language plpgsql as $$
declare
  r text;
begin
  for i in 1 .. n loop
    perform public.sign_in_begin(p_login, p_ip);
    select locked || ':' || retry_after_seconds into r from public.sign_in_failed(p_login, p_ip);
  end loop;
  return r;
end;
$$;
create function pg_temp.begin(p_login text, p_ip text default '198.51.100.7') returns text language sql as $$
  select allowed || ':' || retry_after_seconds from public.sign_in_begin(p_login, p_ip);
$$;

-- ══ Structure and access ═════════════════════════════════════════════════
select ok((select relrowsecurity from pg_class where oid = 'public.sign_in_lockouts'::regclass), 'sign_in_lockouts: RLS enabled');
select is((select count(*)::int from pg_policy where polrelid = 'public.sign_in_lockouts'::regclass), 0, 'sign_in_lockouts: no policies');
select is(pg_temp.reads($$select * from public.sign_in_lockouts$$), '{42501,42501,42501,42501,42501,42501,42501,42501}',
  'sign_in_lockouts: no client role reads it (owner, manager, lead, viewer, display, other tenant, anon)');
select is(pg_temp.writes($$insert into public.sign_in_lockouts (key_hash, key_kind) values (repeat('a', 64), 'login')$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'sign_in_lockouts: no client role writes it');
select is(
  (select array_agg(p.proname::text || ':' || has_function_privilege('authenticated', p.oid, 'execute') || has_function_privilege('anon', p.oid, 'execute')
                    || has_function_privilege('service_role', p.oid, 'execute') order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'sign\_in\_%'),
  '{sign_in_begin:falsefalsetrue,sign_in_failed:falsefalsetrue,sign_in_lock_status:falsefalsetrue,sign_in_succeeded:falsefalsetrue,sign_in_unlock:falsefalsetrue}',
  'the sign_in_* RPCs: service role only (not authenticated, not anon)');
select is(array[
  pg_temp.run_as('owner', $$select public.sign_in_unlock('denise@accounts.adbheadquarters.com')$$),
  pg_temp.run_as('manager', $$select public.sign_in_begin('x@y.z')$$),
  pg_temp.run_as('anon', $$select public.sign_in_failed('x@y.z')$$),
  pg_temp.run_as('anon', $$select public.sign_in_lock_status('{x@y.z}')$$)],
  '{42501,42501,42501,42501}', 'an owner, a manager and anon cannot call them');
select ok((select bool_and(p.prosecdef and p.proconfig @> array['search_path=""']) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'sign\_in\_%'),
  'the sign_in_* RPCs are security definer with an empty search_path');

-- ══ Validation and keys ══════════════════════════════════════════════════
select is(array[
  pg_temp.as_service($$select public.sign_in_begin(null)$$),
  pg_temp.as_service($$select public.sign_in_begin('  ')$$),
  pg_temp.as_service($$select public.sign_in_begin(repeat('a', 255))$$),
  pg_temp.as_service($$select public.sign_in_begin('x@y.z', repeat('1', 65))$$),
  pg_temp.as_service($$select public.sign_in_lock_status(array_fill('x'::text, array[501]))$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}',
  'login 1–254 chars, ip ≤ 64, ≤ 500 logins per status call');
select is(app.sign_in_key('login', '  Denise@Accounts.ADBheadquarters.com '), app.sign_in_key('login', 'denise@accounts.adbheadquarters.com'),
  'logins are normalised (trimmed, lowercased) before hashing');
select is(pg_temp.begin('denise@accounts.adbheadquarters.com'), 'true:0', 'a first attempt is allowed');
select ok((select bool_and(key_hash ~ '^[0-9a-f]{64}$') and bool_and(key_hash <> 'denise@accounts.adbheadquarters.com')
                  and count(*) = 2 from public.sign_in_lockouts),
  'one row per login and per IP, keyed by a SHA-256 hash (the typed login and the IP are never stored)');

-- ══ Lock after 5 failures within 15 minutes ══════════════════════════════
select is(public.sign_in_failed('denise@accounts.adbheadquarters.com', '198.51.100.7')::text, '(f,0)', 'failure 1: not locked');
select is(pg_temp.fail('denise@accounts.adbheadquarters.com', 3), 'false:0', 'failures 2–4: not locked');
select is(pg_temp.fail('denise@accounts.adbheadquarters.com', 1), 'true:900', 'failure 5: locked for 15 minutes');
select is(pg_temp.begin('denise@accounts.adbheadquarters.com'), 'false:900', 'while locked every attempt is refused before the password is checked');
select is((pg_temp.lk('denise@accounts.adbheadquarters.com')).attempts, 5, 'refused attempts are not counted');
select is((select array_agg(login || '>' || (locked_until = now() + interval '15 minutes')) from public.sign_in_lock_status(
             '{denise@accounts.adbheadquarters.com,lead@a.test}')),
  '{denise@accounts.adbheadquarters.com>true}', 'sign_in_lock_status lists the locked login and its lock end only');

-- ══ account_locked alert (owners only, quiet by default) ════════════════
select is((select array_agg(a.plant_id::text || '/' || a.subject_id::text || '/' || a.recipients::text) from public.alert_events a where a.kind = 'account_locked'),
  array[pg_temp.id('plantA')::text || '/' || pg_temp.id('manager')::text || '/{quiet}'],
  'one account_locked alert per plant of the account (subject = the user); default level quiet (no push)');
select is((select app.alert_payload(a) - 'locked_until' from public.alert_events a where a.kind = 'account_locked'),
  jsonb_build_object('user_id', pg_temp.id('manager'), 'username', 'denise', 'failures', 5, 'still_locked', true),
  'payload: user id, username, failures, still_locked');
select is((select (app.alert_payload(a) ->> 'locked_until')::timestamptz from public.alert_events a where a.kind = 'account_locked'),
  date_trunc('second', now() + interval '15 minutes'), 'payload: locked_until');
select ok((select app.alert_payload(a)::text !~* '(@|198\.51|Manager A|password)' from public.alert_events a where a.kind = 'account_locked'),
  'payload: no email, no IP, no profile name, nothing about the password');
select is((select array_agg(app.alert_visible_to(a, pg_temp.id(u)) order by o) from public.alert_events a
             cross join unnest(array['owner', 'ownerP', 'manager', 'lead', 'ownerB']) with ordinality x(u, o)
            where a.kind = 'account_locked'),
  '{t,t,f,f,f}', 'the plant''s owners see it in the Alerts tab; managers, leads and other tenants never');
select is(pg_temp.val_as('owner', $$select (public.set_alert_level(pg_temp.mid('owner'), 'account_locked', 'push')).alert_levels ->> 'account_locked'$$),
  'push', 'an owner can turn account_locked to push');
select is(array[app.alert_level_default('account_locked'), (select app.push_alert_kinds() @> '{account_locked}')::text,
                (select app.owner_alert_kinds() @> '{account_locked}')::text],
  '{quiet,true,true}', 'account_locked: an owner information kind, quiet by default, in the Alerts tab / push pipeline');

-- ══ Unknown logins behave the same (no oracle) ═══════════════════════════
select is(array[pg_temp.fail('nobody-here@accounts.adbheadquarters.com', 4, '203.0.113.9'),
                pg_temp.fail('nobody-here@accounts.adbheadquarters.com', 1, '203.0.113.9'),
                pg_temp.begin('nobody-here@accounts.adbheadquarters.com', '203.0.113.9')],
  '{false:0,true:900,false:900}', 'an unknown login: the same 4 × not locked, locked at 5, then refused');
select is((select count(*)::int from public.alert_events where kind = 'account_locked'), 1, '… and no alert (no account behind it)');

-- ══ Unlock, success, windows ═════════════════════════════════════════════
select is(array[public.sign_in_unlock('Denise@accounts.adbheadquarters.com')::text, public.sign_in_unlock('denise@accounts.adbheadquarters.com')::text,
                pg_temp.begin('denise@accounts.adbheadquarters.com')],
  '{true,false,true:0}', 'an owner unlock (via manage-users) clears the lock: true, then nothing left; sign-in allowed again');
select is((select app.alert_payload(a) ->> 'still_locked' from public.alert_events a where a.kind = 'account_locked'), 'false',
  'the alert now says still_locked = false (send-alerts marks it stale)');
select is(pg_temp.fail('denise@accounts.adbheadquarters.com', 1), 'false:0', 'after the unlock the count starts again');
select public.sign_in_succeeded('denise@accounts.adbheadquarters.com', '198.51.100.7');
select ok(pg_temp.lk('denise@accounts.adbheadquarters.com') is null, 'a correct password clears the login''s counter');
select pg_temp.fail('lead@a.test', 4);
update public.sign_in_lockouts set window_started_at = now() - interval '16 minutes' where key_hash = app.sign_in_key('login', 'lead@a.test');
select is(array[pg_temp.begin('lead@a.test'), (pg_temp.lk('lead@a.test')).attempts::text],
  '{true:0,1}', 'failures older than the 15-minute window are forgotten');
select pg_temp.fail('lead@a.test', 4);
update public.sign_in_lockouts set locked_until = now() - interval '1 second' where key_hash = app.sign_in_key('login', 'lead@a.test');
select is(array[pg_temp.begin('lead@a.test'), (pg_temp.lk('lead@a.test')).attempts::text, ((pg_temp.lk('lead@a.test')).locked_until is null)::text],
  '{true:0,1,true}', 'a lock that has ended: attempts start again from 1');
delete from public.sign_in_lockouts where key_hash = app.sign_in_key('login', 'viewer@a.test');
select is(array(select pg_temp.begin('viewer@a.test', '192.0.2.50') from generate_series(1, 6)),
  '{true:0,true:0,true:0,true:0,true:0,false:900}',
  'a burst of parallel attempts (none finished yet): at most 5 guesses, the 6th is refused and locks the login');

-- ══ IP limit ═════════════════════════════════════════════════════════════
select is(array(select pg_temp.begin('user' || i || '@x.test', '192.0.2.99') from generate_series(1, 31) i) @> '{false:900}'
            and (select pg_temp.begin('user1@x.test', '192.0.2.99')) = 'false:900'
            and (select pg_temp.begin('user1@x.test', '192.0.2.100')) = 'true:0',
  true, 'one IP: 30 attempts per 15 minutes, then refused for any login; another IP is not affected');
select is((select attempts from public.sign_in_lockouts where key_hash = app.sign_in_key('ip', '192.0.2.100')), 1,
  'the IP counter … ');
select public.sign_in_succeeded('user1@x.test', '192.0.2.100');
select is((select attempts from public.sign_in_lockouts where key_hash = app.sign_in_key('ip', '192.0.2.100')), 0,
  '… gets a successful attempt back');

-- ══ Purge ════════════════════════════════════════════════════════════════
update public.sign_in_lockouts set updated_at = now() - interval '2 days';
select cmp_ok(app.purge_sign_in_lockouts(), '>', 0, 'the daily purge removes old counters …');
select is(not exists (select 1 from public.sign_in_lockouts where locked_until is null or locked_until < now())
            and exists (select 1 from public.sign_in_lockouts where locked_until > now())
            and exists (select 1 from cron.job where jobname = 'purge-sign-in-lockouts' and schedule = '41 4 * * *'),
  true, '… keeps live locks, and runs daily (pg_cron purge-sign-in-lockouts)');

select * from finish();
rollback;
