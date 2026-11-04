-- Owner decisions 2026-11-04: a PIN is good for 10 minutes (start_staff_session returns expires_at;
-- ADB plant staff_pin_reuse_minutes = 10); record_soil_estimate keeps an offline entry's real time
-- (p_entered_at).
begin;
\ir _fixtures.psql
select plan(15);

insert into public.entry_staff (id, org_id, plant_id, display_name, pin_hash) values
  ('b0000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Ben', extensions.crypt('1470', extensions.gen_salt('bf')));

-- ══ start_staff_session.expires_at ═══════════════════════════════════════
select is((select array_agg(attname::text order by attnum) from pg_attribute
            where attrelid = 'public.staff_session_result'::regclass and attnum > 0 and not attisdropped),
  array['staff_session_id', 'error', 'locked_until', 'expires_at'], 'result type: expires_at added last (backward compatible)');
select is(pg_temp.val_as('manager', $$select ((r).expires_at - now())::text from (select public.start_staff_session('b0000000-0000-0000-0000-0000000000a2', '1470') r) x$$),
  '00:02:00', 'reuse 0 (fixture default): the single-use session expires in 2 minutes');
update public.plants set staff_pin_reuse_minutes = 10 where id = pg_temp.id('plantA');
select set_config('test.s', pg_temp.val_as('manager', $$select row((r).staff_session_id, (r).expires_at - now())::text from (select public.start_staff_session('b0000000-0000-0000-0000-0000000000a2', '1470') r) x$$), true);
select is(split_part(trim(both '()' from current_setting('test.s')), ',', 2), '00:10:00', 'reuse 10: expires_at = now + 10 minutes');
select is((select expires_at - confirmed_at from public.staff_sessions where id = split_part(trim(both '()' from current_setting('test.s')), ',', 1)::uuid),
  interval '10 minutes', 'the stored session matches the returned expires_at');
select is(pg_temp.val_as('manager', $$select row((r).staff_session_id is null, (r).error, (r).expires_at is null)::text from (select public.start_staff_session('b0000000-0000-0000-0000-0000000000a2', '0000') r) x$$),
  '(t,PIN_INVALID,t)', 'wrong PIN: no session, no expires_at');
select is(array[
  pg_temp.run_as('manager', format($$select public.record_soil_estimate(pg_temp.id('gNapkin'), 2, 'load', gen_random_uuid(), %L)$$, split_part(trim(both '()' from current_setting('test.s')), ',', 1))),
  pg_temp.run_as('manager', format($$select public.record_soil_estimate(pg_temp.id('gMat'), 3, 'load', gen_random_uuid(), %L)$$, split_part(trim(both '()' from current_setting('test.s')), ',', 1)))],
  '{1,1}', 'within the window one PIN confirms several entries');

-- ══ ADB plant: 10 minutes ════════════════════════════════════════════════
select is((select p.staff_pin_reuse_minutes from public.plants p join public.organizations o on o.id = p.org_id
            where o.slug = 'americas-dust-busters' and p.name = 'Miami'), 10, 'the ADB plant reuses a PIN for 10 minutes');

-- ══ record_soil_estimate.p_entered_at ════════════════════════════════════
create function pg_temp.cid(n int) returns uuid language sql immutable as $$
  select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;
$$;
grant execute on function pg_temp.cid(int) to authenticated, anon;
create function pg_temp.ben() returns uuid language sql as $$
  select (public.start_staff_session('b0000000-0000-0000-0000-0000000000a2', '1470')).staff_session_id;
$$;
grant execute on function pg_temp.ben() to authenticated, anon;
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gTowel'), 4, 'load', pg_temp.cid(1), pg_temp.ben(), p_entered_at => now() - interval '20 minutes')$$),
  '1', 'an offline estimate entered 20 minutes ago');
select is((select entered_at from public.soil_estimates where client_id = pg_temp.cid(1)), now() - interval '20 minutes',
  'entered_at = the device time');
select is(array[
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gTowel'), 4, 'load', gen_random_uuid(), pg_temp.ben(), p_entered_at => now() - interval '31 minutes')$$),
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gTowel'), 4, 'load', gen_random_uuid(), pg_temp.ben(), p_entered_at => now() + interval '2 minutes')$$)],
  '{OUT_OF_RANGE_TIMESTAMP,OUT_OF_RANGE_TIMESTAMP}', 'p_entered_at outside [now − 30 min, now + 1 min] is rejected');
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gTowel'), 6, 'load', pg_temp.cid(2), pg_temp.ben(), p_entered_at => now() + interval '30 seconds')$$),
  '1', 'up to 1 minute ahead is accepted (device clock skew)');
select is(pg_temp.val_as('manager', $$select (public.record_soil_estimate(pg_temp.id('gTowel'), 4, 'load', pg_temp.cid(1), null, p_entered_at => now() - interval '3 hours')).id::text$$),
  (select id::text from public.soil_estimates where client_id = pg_temp.cid(1)),
  'idempotency comes first: a late retry of a saved estimate returns it (no window, no session needed)');
select is(pg_temp.run_as('ownerB', $$select public.record_soil_estimate(pg_temp.id('gTowel'), 4, 'load', gen_random_uuid(), null, p_entered_at => now() - interval '3 hours')$$),
  'NOT_AUTHORIZED', 'role check first: another tenant learns nothing');
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gTowel'), 1, 'load', pg_temp.cid(3), pg_temp.ben(), p_entered_at => now() - interval '25 minutes')$$),
  '1', 'a late-syncing older estimate is saved …');
select is((select qty from public.current_soil_estimates where wash_group_id = pg_temp.id('gTowel')), 6.00::numeric,
  '… but does not override a newer one (current = latest entered_at)');

select * from finish();
rollback;
