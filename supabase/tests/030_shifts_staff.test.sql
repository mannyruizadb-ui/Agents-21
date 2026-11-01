-- A6/A8: shifts, shift_instances, entry_staff (+ entry_staff_public), staff_sessions; generation, DST,
-- resolve_entry_shift, PIN RPCs, set_shift_skipped.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(89);

-- ── shifts / shift_instances matrix ──────────────────────────────────────
select is(pg_temp.reads($$select 1 from public.shifts where plant_id = pg_temp.id('plantA')$$), '{8,8,8,8,8,0,0,0}', 'shifts R');
select is(pg_temp.reads($$select 1 from public.shift_instances where plant_id = pg_temp.id('plantA')$$), '{25,25,25,25,25,0,0,0}', 'shift_instances R');
select is(pg_temp.writes($$insert into public.shifts (org_id, plant_id, area_id, name, start_local, end_local, days_of_week, active)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'S-' || substr(md5(random()::text), 1, 6), '20:00', '21:00', '{0}', false)$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'shifts C owner/manager');
select is(pg_temp.writes($$update public.shifts set active = active where plant_id = pg_temp.id('plantA')$$), '{10,10,0,0,0,0,0,0}', 'shifts U owner/manager');
select is(pg_temp.writes($$insert into public.shift_instances (org_id, plant_id, area_id, shift_id, business_date, starts_at, ends_at)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('finDay'), '2026-12-01', now(), now() + interval '1 hour')$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'shift_instances C denied (generated only)');
select is(pg_temp.writes($$update public.shift_instances set skipped_at = now()$$), '{0,0,0,0,0,0,0,0}', 'shift_instances U denied (set_shift_skipped only)');

-- ── generation: a normal week from a fixed p_from (fixtures: Mon 2026-11-02, 7 days) ──
select is((select count(*)::int from public.shift_instances where area_id = pg_temp.id('fin')), 15, 'finishing: 6 Evening + 5 Night + 4 Day');
select is((select count(*)::int from public.shift_instances where area_id = pg_temp.id('wash')), 10, 'washroom: 6 Evening + 4 Night');
select is((select count(*)::int from public.shift_instances where business_date = '2026-11-08'), 0, 'Sunday closed: no instances');
select is((select count(*)::int from public.shift_instances
            where shift_id = pg_temp.id('washNight') and business_date = '2026-11-05'), 0, 'no washroom Night on Thursday');
select is((select array[starts_at, ends_at] from public.shift_instances where shift_id = pg_temp.id('finEvening') and business_date = '2026-11-02'),
  array[pg_temp.ny('2026-11-02 16:00'), pg_temp.ny('2026-11-03 00:00')], 'Mon finishing Evening 16:00–24:00 ends next day');
select is((select array[starts_at, ends_at] from public.shift_instances
            where shift_id = '90000000-0000-0000-0000-0000000000f4' and business_date = '2026-11-05'),
  array[pg_temp.ny('2026-11-05 00:00'), pg_temp.ny('2026-11-05 05:00')], 'Thu finishing Night variant ends 05:00');
select is((select array[starts_at, ends_at] from public.shift_instances
            where shift_id = '90000000-0000-0000-0000-0000000000e2' and business_date = '2026-11-05'),
  array[pg_temp.ny('2026-11-05 15:00'), pg_temp.ny('2026-11-06 00:00')], 'Thu washroom Evening variant starts 15:00');
select is((select array[starts_at, ends_at] from public.shift_instances where shift_id = pg_temp.id('finNight') and business_date = '2026-11-03'),
  array[pg_temp.ny('2026-11-03 00:00'), pg_temp.ny('2026-11-03 10:00')], 'Night 00:00–10:00 belongs to the day it starts');
select is(app.generate_shift_instances(pg_temp.id('plantA'), 7, '2026-11-02'), 0, 'idempotent: re-run changes nothing');
select is((select count(*)::int from public.shift_instances where plant_id = pg_temp.id('plantA')), 25, 'idempotent: no duplicates');

-- DST (plant B, hypothetical Saturday-night shift 22:00–06:00).
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week)
values ('90000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), 'Overnight', '22:00', '06:00', '{6}');
select is(app.generate_shift_instances(pg_temp.id('plantB'), 1, '2026-10-31'), 1, 'DST: one instance generated');
select is((select array[starts_at, ends_at] from public.shift_instances
            where shift_id = '90000000-0000-0000-0000-0000000000b1' and business_date = '2026-10-31'),
  array['2026-11-01 02:00+00'::timestamptz, '2026-11-01 11:00+00'::timestamptz], 'fall-back night: 22:00 EDT → 06:00 EST');
select is((select ends_at - starts_at from public.shift_instances
            where shift_id = '90000000-0000-0000-0000-0000000000b1' and business_date = '2026-10-31'),
  interval '9 hours', 'fall-back (2026-11-01) night lasts 9 h');
select is(app.generate_shift_instances(pg_temp.id('plantB'), 1, '2026-03-07'), 1, 'spring-forward instance generated');
select is((select ends_at - starts_at from public.shift_instances
            where shift_id = '90000000-0000-0000-0000-0000000000b1' and business_date = '2026-03-07'),
  interval '7 hours', 'spring-forward (2026-03-08) night lasts 7 h');
select lives_ok($$select app.generate_shift_instances(pg_temp.id('plantB'), 1)$$, 'p_from defaults to plant-local today');

-- Validation + privileges.
select throws_ok($$select app.generate_shift_instances(pg_temp.id('plantA'), 0)$$, 'P0001', 'VALIDATION_FAILED', 'p_days >= 1');
select throws_ok($$select app.generate_shift_instances(pg_temp.id('plantA'), 61)$$, 'P0001', 'VALIDATION_FAILED', 'p_days <= 60');
select throws_ok($$select app.generate_shift_instances(gen_random_uuid(), 7)$$, 'P0001', 'VALIDATION_FAILED', 'unknown plant');
select is(pg_temp.run_as('owner', $$select app.generate_shift_instances(pg_temp.id('plantA'), 1)$$), '42501', 'clients cannot run generation');
select throws_ok($$insert into public.shifts (org_id, plant_id, area_id, name, start_local, end_local, days_of_week)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Bad', '08:00', '09:00', '{7}')$$, '23514', null, 'days_of_week 0–6');

-- D7: overlap is rejected per AREA, allowed across areas.
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week) values
  ('90000000-0000-0000-0000-0000000000c1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), 'Overlap', '09:00', '11:00', '{2}');
select throws_ok($$select app.generate_shift_instances(pg_temp.id('plantA'), 1, '2026-11-10')$$, '23P01', null,
  'overlapping shifts within one area are rejected');
update public.shifts set active = false where id = '90000000-0000-0000-0000-0000000000c1';
insert into public.shifts (org_id, plant_id, area_id, name, start_local, end_local, days_of_week) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Overlap', '09:00', '11:00', '{2}');
select lives_ok($$select app.generate_shift_instances(pg_temp.id('plantA'), 1, '2026-11-10')$$, 'the same hours in another area are fine');

-- Clock lookup.
select is(app.shift_instance_at(pg_temp.id('fin'), pg_temp.ny('2026-11-03 11:30')), pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03'), 'shift_instance_at finds the containing instance');
select is(app.shift_instance_at(pg_temp.id('fin'), pg_temp.ny('2026-11-03 10:00')), pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03'), 'ranges are half-open (10:00 is Day)');
select is(app.shift_instance_at(pg_temp.id('wash'), pg_temp.ny('2026-11-03 13:00')), null, 'washroom midday is off-shift');

-- ── entry_staff ──────────────────────────────────────────────────────────
insert into public.entry_staff (id, org_id, plant_id, display_name, home_shift_id, active) values
  ('b0000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Ana',  pg_temp.id('finNight'), true),
  ('b0000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Ben',  null, true),
  ('b0000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Cara', pg_temp.id('washNight'), true),
  ('b0000000-0000-0000-0000-0000000000a4', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Dee',  null, false),
  ('b0000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), 'Zed',  null, true);

select is(pg_temp.reads($$select id, display_name, has_pin from public.entry_staff where plant_id = pg_temp.id('plantA')$$),
  '{4,4,4,0,0,0,0,42501}', 'entry_staff R owner/manager/lead (non-secret columns)');
select is(pg_temp.reads($$select 1 from public.entry_staff_public where plant_id = pg_temp.id('plantA')$$),
  '{4,4,4,0,0,0,0,42501}', 'entry_staff_public R owner/manager/lead');
select is(pg_temp.reads($$select pin_hash from public.entry_staff$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'D2: pin_hash never selectable');
select is(pg_temp.reads($$select failed_pin_attempts, locked_until from public.entry_staff$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'D2: lockout counters never selectable');
select is(pg_temp.run_as('owner', $$select * from public.entry_staff$$, true), '42501', 'select * is denied (includes pin_hash)');
select is(pg_temp.writes($$insert into public.entry_staff (org_id, plant_id, display_name)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'N-' || substr(md5(random()::text), 1, 8))$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'entry_staff C owner/manager');
select is(pg_temp.writes($$update public.entry_staff set active = active where plant_id = pg_temp.id('plantA')$$),
  '{6,6,0,0,0,0,0,42501}', 'entry_staff U owner/manager');
select is(array[pg_temp.run_as('owner', $$insert into public.entry_staff (org_id, plant_id, display_name, pin_hash)
                                           values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Eve', 'x')$$),
                pg_temp.run_as('owner', $$update public.entry_staff set pin_hash = 'x'$$),
                pg_temp.run_as('owner', $$update public.entry_staff set failed_pin_attempts = 0$$),
                pg_temp.run_as('owner', $$insert into public.entry_staff_public (org_id, plant_id, display_name)
                                           values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Eve')$$)],
  '{42501,42501,42501,42501}', 'D2: secrets not insertable/updatable; the view is read-only');
select is(pg_temp.run_as('manager', $$update public.entry_staff set language = 'ht' where display_name = 'Ana'$$),
  'VALIDATION_FAILED', 'staff language must be enabled for the plant');
select is(pg_temp.reads($$select 1 from public.staff_sessions$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'D3: staff_sessions are RPC-only');

-- ── set_staff_pin ────────────────────────────────────────────────────────
select is(pg_temp.run_as('manager', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a1', '4821')$$), '1', 'manager sets a PIN');
select ok((select pin_hash like '$2_$%' and has_pin from public.entry_staff where display_name = 'Ana'), 'PIN is bcrypt-hashed; has_pin true');
select is(array[pg_temp.run_as('owner', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a2', '0000')$$),
                pg_temp.run_as('owner', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a2', '1234')$$),
                pg_temp.run_as('owner', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a2', '7777')$$),
                pg_temp.run_as('owner', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a2', '12a4')$$),
                pg_temp.run_as('owner', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a2', '123')$$),
                pg_temp.run_as('owner', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a2', '12345')$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}',
  'weak or malformed PINs rejected');
select is(pg_temp.run_as('owner', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a2', '4821')$$),
  'VALIDATION_FAILED', 'a PIN used by another active person is rejected');
select is(pg_temp.run_as('owner', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a2', '5930')$$), '1', 'owner sets a PIN');
select is(pg_temp.writes($$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a1', '4821')$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'set_staff_pin owner/manager only');
select is((select count(*)::int from public.audit_log where entity = 'entry_staff' and entity_id = 'b0000000-0000-0000-0000-0000000000a1'
            and action = 'entry_staff.pin_set'), 3, 'PIN changes are audited');
select is((select count(*)::int from public.audit_log where entity = 'entry_staff' and (before ? 'pin_hash' or after ? 'pin_hash')),
  0, 'D12: audit never stores pin_hash');

-- ── start_staff_session ──────────────────────────────────────────────────
select is(pg_temp.run_as('lead', $$select 1 from public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '4821') s
                                   where s.staff_session_id is not null and s.error is null and s.locked_until is null$$, true),
  '1', 'lead confirms name + PIN and gets a session');
select is((select array[(expires_at - confirmed_at)::text, auth_user_id::text, org_id::text] from public.staff_sessions
            where staff_id = 'b0000000-0000-0000-0000-0000000000a1'),
  array['00:02:00', pg_temp.id('lead')::text, pg_temp.id('orgA')::text], 'reuse 0 → session expires after 2 min, bound to the caller');
update public.plants set staff_pin_reuse_minutes = 10 where id = pg_temp.id('plantA');
select is(pg_temp.run_as('manager', $$select 1 from public.start_staff_session('b0000000-0000-0000-0000-0000000000a2', '5930') s
                                      where s.staff_session_id is not null$$, true), '1', 'manager may start a session');
select is((select expires_at - confirmed_at from public.staff_sessions where staff_id = 'b0000000-0000-0000-0000-0000000000a2'),
  interval '10 minutes', 'session lasts staff_pin_reuse_minutes');
update public.plants set staff_pin_reuse_minutes = 0 where id = pg_temp.id('plantA');
select is(array[pg_temp.run_as('viewer', $$select public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '4821')$$),
                pg_temp.run_as('display', $$select public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '4821')$$),
                pg_temp.run_as('ownerB', $$select public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '4821')$$),
                pg_temp.run_as('anon', $$select public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '4821')$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'viewer, display, other tenant and anon cannot start sessions');
select is(array[pg_temp.run_as('lead', $$select 1 from public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '0001') where error = 'PIN_INVALID'$$, true),
                pg_temp.run_as('lead', $$select 1 from public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '0001') where error = 'PIN_INVALID'$$, true),
                pg_temp.run_as('lead', $$select 1 from public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '0001') where error = 'PIN_INVALID'$$, true),
                pg_temp.run_as('lead', $$select 1 from public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '0001') where error = 'PIN_INVALID'$$, true)],
  '{1,1,1,1}', 'wrong PIN returns PIN_INVALID (no exception)');
select is((select failed_pin_attempts from public.entry_staff where display_name = 'Ana'), 4, 'failed attempts persist (not rolled back)');
select is(pg_temp.run_as('lead', $$select 1 from public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '0001')
                                   where error = 'STAFF_LOCKED' and locked_until = now() + interval '5 minutes' and staff_session_id is null$$, true),
  '1', '5th failure → STAFF_LOCKED with locked_until = now + 5 min');
select is((select array[failed_pin_attempts::text, (locked_until = now() + interval '5 minutes')::text] from public.entry_staff where display_name = 'Ana'),
  '{0,true}', 'lock set and counter reset');
select is(pg_temp.run_as('lead', $$select 1 from public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '4821') where error = 'STAFF_LOCKED'$$, true),
  '1', 'while locked even the right PIN returns STAFF_LOCKED');
select is((select count(*)::int from public.audit_log where entity_id = 'b0000000-0000-0000-0000-0000000000a1' and action = 'entry_staff.update'),
  0, 'D12: lockout-counter updates are not audited');
select is(array[pg_temp.run_as('lead', $$select 1 from public.start_staff_session('b0000000-0000-0000-0000-0000000000a2', '1111') where error = 'PIN_INVALID'$$, true),
                pg_temp.run_as('lead', $$select 1 from public.start_staff_session('b0000000-0000-0000-0000-0000000000a2', '1111') where error = 'PIN_INVALID'$$, true)],
  '{1,1}', 'two wrong PINs for Ben');
select is((select failed_pin_attempts from public.entry_staff where display_name = 'Ben'), 2, 'Ben has 2 failed attempts');
select is(pg_temp.run_as('lead', $$select 1 from public.start_staff_session('b0000000-0000-0000-0000-0000000000a2', '5930') where error is null$$, true),
  '1', 'right PIN succeeds');
select is((select failed_pin_attempts from public.entry_staff where display_name = 'Ben'), 0, 'success resets the failed-attempt counter');
select is(array[pg_temp.run_as('lead', $$select public.start_staff_session('b0000000-0000-0000-0000-0000000000a3', '4821')$$),
                pg_temp.run_as('lead', $$select public.start_staff_session('b0000000-0000-0000-0000-0000000000a4', '4821')$$),
                pg_temp.run_as('lead', $$select public.start_staff_session('b0000000-0000-0000-0000-0000000000a2', 'abcd')$$),
                pg_temp.run_as('lead', $$select public.start_staff_session('b0000000-0000-0000-0000-0000000000b1', '4821')$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,NOT_AUTHORIZED}', 'PIN not set / inactive / bad PIN / other tenant raise');

-- ── set_shift_skipped ────────────────────────────────────────────────────
select is(pg_temp.run_as('manager', $$select 1 from public.set_shift_skipped(pg_temp.si(pg_temp.id('fin'), 'Night', '2026-11-04'), true) s
                                      where s.skipped_at is not null$$, true), '1', 'manager marks an instance "didn''t run"');
select is(array[pg_temp.run_as('lead', $$select public.set_shift_skipped(pg_temp.si(pg_temp.id('fin'), 'Night', '2026-11-04'), false)$$),
                pg_temp.run_as('viewer', $$select public.set_shift_skipped(pg_temp.si(pg_temp.id('fin'), 'Night', '2026-11-04'), false)$$),
                pg_temp.run_as('display', $$select public.set_shift_skipped(pg_temp.si(pg_temp.id('fin'), 'Night', '2026-11-04'), false)$$),
                pg_temp.run_as('ownerB', $$select public.set_shift_skipped(pg_temp.si(pg_temp.id('fin'), 'Night', '2026-11-04'), false)$$),
                pg_temp.run_as('manager', $$select public.set_shift_skipped(pg_temp.si(pg_temp.id('fin'), 'Night', '2026-11-04'), null)$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,VALIDATION_FAILED}', 'set_shift_skipped owner/manager only; p_skipped required');
select is((select count(*)::int from public.audit_log where action = 'shift_instances.update'
            and entity_id = pg_temp.si(pg_temp.id('fin'), 'Night', '2026-11-04')), 1, 'skip is audited');
select is(app.shift_instance_at(pg_temp.id('fin'), pg_temp.ny('2026-11-04 03:00')), null, 'skipped instances are ignored by lookups');

-- ── D5 resolve_entry_shift (Ana: home finishing Night; Ben: none; Cara: home washroom Night) ──
select is(app.resolve_entry_shift('b0000000-0000-0000-0000-0000000000a1', 'own', pg_temp.ny('2026-11-03 11:30'), pg_temp.id('fin')),
  pg_temp.si(pg_temp.id('fin'), 'Night', '2026-11-03'), 'Night person at 11:30 counts as that day''s Night');
select is(app.resolve_entry_shift('b0000000-0000-0000-0000-0000000000a1', 'next', pg_temp.ny('2026-11-03 11:30'), pg_temp.id('fin')),
  pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03'), '"next" gives that day''s Day');
select is(app.resolve_entry_shift('b0000000-0000-0000-0000-0000000000a1', null, pg_temp.ny('2026-11-03 11:30'), pg_temp.id('fin')),
  pg_temp.si(pg_temp.id('fin'), 'Night', '2026-11-03'), 'choice defaults to own');
select is(app.resolve_entry_shift('b0000000-0000-0000-0000-0000000000a1', 'own', pg_temp.ny('2026-11-05 03:00'), pg_temp.id('fin')),
  pg_temp.si(pg_temp.id('fin'), 'Night', '2026-11-05'), 'Thursday Night variant (same name) is the home shift');
select is(app.resolve_entry_shift('b0000000-0000-0000-0000-0000000000a1', 'own', pg_temp.ny('2026-11-03 17:00'), pg_temp.id('fin')),
  pg_temp.si(pg_temp.id('fin'), 'Evening', '2026-11-03'), 'more than 6 h after the home shift → clock fallback');
select is(app.resolve_entry_shift('b0000000-0000-0000-0000-0000000000a1', 'own', pg_temp.ny('2026-11-04 11:30'), pg_temp.id('fin')),
  pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-04'), 'a skipped home instance is not used');
select is(app.resolve_entry_shift('b0000000-0000-0000-0000-0000000000a2', 'own', pg_temp.ny('2026-11-03 11:30'), pg_temp.id('fin')),
  pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03'), 'no home shift → clock-based instance');
select is(app.resolve_entry_shift('b0000000-0000-0000-0000-0000000000a2', 'next', pg_temp.ny('2026-11-03 11:30'), pg_temp.id('fin')),
  pg_temp.si(pg_temp.id('fin'), 'Evening', '2026-11-03'), 'next after the clock-based instance');
select is(app.resolve_entry_shift('b0000000-0000-0000-0000-0000000000a2', 'own', pg_temp.ny('2026-11-08 12:00'), pg_temp.id('fin')),
  null, 'nothing in range → null (off-shift)');
select is(app.resolve_entry_shift('b0000000-0000-0000-0000-0000000000a3', 'own', pg_temp.ny('2026-11-03 11:30'), pg_temp.id('fin')),
  pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03'), 'home shift in another area → clock fallback of the entry area');
select is(app.resolve_entry_shift('b0000000-0000-0000-0000-0000000000a3', 'own', pg_temp.ny('2026-11-03 13:00'), pg_temp.id('wash')),
  pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03'), 'washroom Night staying late (13:00) still counts as Night');
select throws_ok($$select app.resolve_entry_shift('b0000000-0000-0000-0000-0000000000a1', 'later', now(), pg_temp.id('fin'))$$,
  'P0001', 'VALIDATION_FAILED', 'choice must be own or next');
select throws_ok($$select app.resolve_entry_shift('b0000000-0000-0000-0000-0000000000b1', 'own', now(), pg_temp.id('fin'))$$,
  'P0001', 'VALIDATION_FAILED', 'staff and area must be in the same plant');

-- ── D6 re-runs: future unreferenced instances follow edits; past or referenced ones never change ──
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week) values
  ('90000000-0000-0000-0000-0000000000c2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Early', '06:00', '07:00', '{2}');
select ok(app.generate_shift_instances(pg_temp.id('plantA'), 1, '2030-01-08') >= 6, 'future Tuesday generated');
update public.shifts set start_local = '06:30' where id = '90000000-0000-0000-0000-0000000000c2';
select is(app.generate_shift_instances(pg_temp.id('plantA'), 1, '2030-01-08'), 1, 'edited shift updates its future instance');
select is((select starts_at from public.shift_instances where shift_id = '90000000-0000-0000-0000-0000000000c2' and business_date = '2030-01-08'),
  pg_temp.ny('2030-01-08 06:30'), 'future instance has the new start');
insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, entered_by, client_id, shift_instance_id)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 1, pg_temp.id('manager'), gen_random_uuid(),
        pg_temp.si(pg_temp.id('fin'), 'Day', '2030-01-08'));
update public.shifts set start_local = '10:15' where id = pg_temp.id('finDay');
select is(app.generate_shift_instances(pg_temp.id('plantA'), 1, '2030-01-08'), 0, 'a referenced future instance is not changed');
select ok(app.generate_shift_instances(pg_temp.id('plantA'), 1, '2020-01-07') >= 6, 'past Tuesday generated');
update public.shifts set start_local = '06:45' where id = '90000000-0000-0000-0000-0000000000c2';
select is(app.generate_shift_instances(pg_temp.id('plantA'), 1, '2020-01-07'), 0, 'past instances are never changed');

select * from finish();
rollback;
