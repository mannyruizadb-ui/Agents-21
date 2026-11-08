-- Sign-in lockout hardening (owner-approved 2026-11-07; 20261107021204): M3 (an account_locked alert for
-- EVERY lock, including the parallel-burst lock started inside sign_in_begin; deduped on the lock end),
-- M4 (escalating login locks: 15 → 30 → 60 … min within 24 h of the previous lock, capped at 24 h; IP locks
-- stay 15 min; a success or an unlock starts over), account_locked push by default, the purge keeping the
-- escalation memory, and sign_in_account_state (pepper upgrade lookup, service role only).
-- Statements run directly here have service-role semantics (auth.uid() null).
begin;
\ir _fixtures.psql
select plan(21);

create function pg_temp.begin(p_login text, p_ip text default null) returns text language sql as $$
  select allowed || ':' || retry_after_seconds from public.sign_in_begin(p_login, p_ip);
$$;
-- n complete wrong-password attempts (begin + failed); the last failed() result as 'locked:seconds'.
create function pg_temp.fail(p_login text, n int, p_ip text default null) returns text language plpgsql as $$
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
-- n failed() calls only (the attempts were reserved earlier); every result.
create function pg_temp.failed_only(p_login text, n int) returns text[] language plpgsql as $$
declare
  r text[] := '{}';
  v text;
begin
  for i in 1 .. n loop
    select locked || ':' || retry_after_seconds into v from public.sign_in_failed(p_login);
    r := r || v;
  end loop;
  return r;
end;
$$;
create function pg_temp.lk(p text) returns public.sign_in_lockouts language sql as $$
  select * from public.sign_in_lockouts where key_hash = app.sign_in_key('login', p);
$$;
-- Ends the current lock of a login (as if its time had passed), keeping the escalation memory.
create function pg_temp.end_lock(p text, p_ago interval default interval '1 second') returns void language sql as $$
  update public.sign_in_lockouts set locked_until = now() - p_ago, last_locked_until = now() - p_ago
   where key_hash = app.sign_in_key('login', p);
$$;
create function pg_temp.locks(p_user text) returns int language sql as $$
  select count(*)::int from public.alert_events where kind = 'account_locked' and subject_id = pg_temp.id(p_user);
$$;

-- ══ M3: a parallel burst locks inside sign_in_begin AND alerts ═══════════
select is(array(select pg_temp.begin('manager@a.test') from generate_series(1, 6)),
  '{true:0,true:0,true:0,true:0,true:0,false:900}', 'a burst of 6 parallel attempts: 5 reserved, the 6th locks the login in sign_in_begin');
select is(pg_temp.locks('manager'), 1, 'M3: that lock writes the account_locked alert (it used to be written only by sign_in_failed)');
select is(pg_temp.failed_only('manager@a.test', 5),
  '{true:900,true:900,true:900,true:900,true:900}', 'the 5 reserved attempts then fail: all report the lock …');
select is(pg_temp.locks('manager'), 1, '… and no second alert for the same lock (dedupe on the lock end)');
select is((select dedupe_key from public.alert_events where kind = 'account_locked' and subject_id = pg_temp.id('manager')),
  floor(extract(epoch from (pg_temp.lk('manager@a.test')).locked_until))::bigint::text, 'dedupe_key = the lock end (epoch seconds)');
select is((select recipients::text from public.alert_events where kind = 'account_locked' and subject_id = pg_temp.id('manager')), '{}',
  'account_locked is push by default (pending for the owners'' push)');

-- ══ M4: escalation ═══════════════════════════════════════════════════════
select pg_temp.end_lock('manager@a.test');
select is(pg_temp.fail('manager@a.test', 5), 'true:1800', 'a new lock within 24 h of the previous one: 30 minutes');
select is(pg_temp.locks('manager'), 2, 'every new lock is a new alert');
select pg_temp.end_lock('manager@a.test');
select is(pg_temp.fail('manager@a.test', 5), 'true:3600', 'the next: 60 minutes');
select is((pg_temp.lk('manager@a.test')).lock_level::int, 2, 'lock_level records the step (0 = 15 min)');
select pg_temp.end_lock('manager@a.test', interval '25 hours');
select is(pg_temp.fail('manager@a.test', 5), 'true:900', 'more than 24 h after the previous lock ended: back to 15 minutes');
select is(array[app.sign_in_lock_length(0), app.sign_in_lock_length(1), app.sign_in_lock_length(6), app.sign_in_lock_length(7), app.sign_in_lock_length(10)],
  array[interval '15 minutes', interval '30 minutes', interval '960 minutes', interval '24 hours', interval '24 hours'],
  'lock length 15 min × 2^level, capped at 24 hours');
update public.sign_in_lockouts set lock_level = 9, last_locked_until = now() - interval '1 second', locked_until = now() - interval '1 second'
 where key_hash = app.sign_in_key('login', 'manager@a.test');
select is(pg_temp.fail('manager@a.test', 5), 'true:86400', 'a long series stays at the 24-hour cap');
select is(array[public.sign_in_unlock('manager@a.test')::text, pg_temp.fail('manager@a.test', 5)], '{true,true:900}',
  'an owner unlock starts over (the next lock is 15 minutes again)');
select pg_temp.end_lock('manager@a.test');
select public.sign_in_succeeded('manager@a.test');
select is(pg_temp.fail('manager@a.test', 5), 'true:900', 'a correct password starts over too');

-- IP locks do not escalate.
select is(array(select pg_temp.begin('ip' || i || '@x.test', '192.0.2.77') from generate_series(1, 31) i) @> '{false:900}', true,
  'an IP: 30 attempts, then 15 minutes …');
update public.sign_in_lockouts set locked_until = now() - interval '1 second' where key_hash = app.sign_in_key('ip', '192.0.2.77');
select is(array(select pg_temp.begin('ipb' || i || '@x.test', '192.0.2.77') from generate_series(1, 31) i) @> '{false:900}', true,
  '… and the next IP lock is 15 minutes again (no escalation for IPs; no alert either)');

-- ══ Purge keeps the escalation memory ════════════════════════════════════
update public.sign_in_lockouts set updated_at = now() - interval '2 days';
update public.sign_in_lockouts set locked_until = now() - interval '2 hours', last_locked_until = now() - interval '2 hours'
 where key_hash = app.sign_in_key('login', 'manager@a.test');
select app.purge_sign_in_lockouts();
select ok(pg_temp.lk('manager@a.test') is not null, 'the purge keeps a counter whose lock ended less than 24 h ago …');
update public.sign_in_lockouts set locked_until = now() - interval '25 hours', last_locked_until = now() - interval '25 hours'
 where key_hash = app.sign_in_key('login', 'manager@a.test');
select app.purge_sign_in_lockouts();
select ok(pg_temp.lk('manager@a.test') is null, '… and removes it once that is more than 24 h ago');

-- ══ sign_in_account_state (pepper upgrade lookup) ════════════════════════
update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"pw_v": 2}' where id = pg_temp.id('lead');
select is(array[
  (select legacy_password::text from public.sign_in_account_state('Manager@A.test ')),
  (select legacy_password::text from public.sign_in_account_state('lead@a.test')),
  (select legacy_password::text from public.sign_in_account_state('nobody-here@x.test')),
  pg_temp.as_service($$select public.sign_in_account_state(' ')$$)],
  '{true,false,false,VALIDATION_FAILED}',
  'legacy_password: true only for an existing account without pw_v = 2 (normalised login); false for peppered and unknown logins');
select is(array[pg_temp.run_as('owner', $$select public.sign_in_account_state('manager@a.test')$$),
                pg_temp.run_as('anon', $$select public.sign_in_account_state('manager@a.test')$$)],
  '{42501,42501}', 'sign_in_account_state: service role only');

select * from finish();
rollback;
