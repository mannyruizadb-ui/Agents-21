-- Security review 2026-11-04 fixes on machine down (migration 20261104165713_harden_machine_status):
-- L3/L4 column-level SELECT without entered_by and no MAINTAIN; L6 down reasons only for owner and
-- managers; L5 one machine_down alert per machine per 10 minutes; L1 backdated taps on a washer
-- that is down now must be ≥ 60 s before the down event.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(20);

insert into public.machines (id, org_id, plant_id, area_id, name, kind, active) values
  ('60000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 3', 'washer', true),
  ('60000000-0000-0000-0000-0000000000a4', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Dryer 1', 'dryer', true);

-- ══ L3/L4: privileges ════════════════════════════════════════════════════
select is(array[has_column_privilege('authenticated', 'public.machine_status_events', 'entered_by', 'select'),
                has_column_privilege('authenticated', 'public.machine_status_events', 'reason', 'select'),
                has_column_privilege('authenticated', 'public.machine_status_events', 'occurred_at', 'select')],
  array[false, false, true], 'authenticated: no SELECT on entered_by or reason (2026-11-04: reasons only through the RPCs)');
select is(array[has_table_privilege('authenticated', 'public.machine_status_events', 'MAINTAIN'),
                has_table_privilege('authenticated', 'public.machine_status_events', 'INSERT'),
                has_table_privilege('authenticated', 'public.machine_status_events', 'UPDATE'),
                has_table_privilege('authenticated', 'public.machine_status_events', 'DELETE'),
                has_table_privilege('authenticated', 'public.machine_status_events', 'TRUNCATE'),
                has_table_privilege('authenticated', 'public.machine_status_events', 'REFERENCES'),
                has_table_privilege('authenticated', 'public.machine_status_events', 'TRIGGER'),
                has_any_column_privilege('anon', 'public.machine_status_events', 'SELECT')],
  array[false, false, false, false, false, false, false, false],
  'no MAINTAIN, no write privileges for authenticated; nothing for anon');

select is(pg_temp.run_as('owner', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), 'Ana hurt her hand on the door')$$),
  '1', 'Washer 1 marked down with a free-text reason');
select is(pg_temp.writes($$select entered_by from public.machine_status_events$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'nobody reads entered_by through the API (not even the owner)');
select is(pg_temp.writes($$select reason from public.machine_status_events$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'no role reads the free-text reason from the table (lead and viewer included)');
select is(pg_temp.reads($$select id, seq, org_id, plant_id, machine_id, status, occurred_at, client_id, created_at from public.machine_status_events$$),
  '{1,1,1,1,0,0,0,42501}', 'the other columns stay readable under RLS (plant roles only)');

-- ══ L6: reasons only for owner and managers ══════════════════════════════
select is(array[
  pg_temp.val_as('owner',   $$select coalesce(down_reason, 'null') || ':' || is_down from public.get_washroom_board(pg_temp.id('wash')) where machine_name = 'Washer 1'$$),
  pg_temp.val_as('manager', $$select coalesce(down_reason, 'null') || ':' || is_down from public.get_washroom_board(pg_temp.id('wash')) where machine_name = 'Washer 1'$$),
  pg_temp.val_as('lead',    $$select coalesce(down_reason, 'null') || ':' || is_down from public.get_washroom_board(pg_temp.id('wash')) where machine_name = 'Washer 1'$$),
  pg_temp.val_as('viewer',  $$select coalesce(down_reason, 'null') || ':' || is_down from public.get_washroom_board(pg_temp.id('wash')) where machine_name = 'Washer 1'$$),
  pg_temp.val_as('display', $$select coalesce(down_reason, 'null') || ':' || is_down from public.get_washroom_board(pg_temp.id('wash')) where machine_name = 'Washer 1'$$)],
  array['Ana hurt her hand on the door:true', 'Ana hurt her hand on the door:true', 'null:true', 'null:true', 'null:true'],
  'get_washroom_board: down_reason for owner/manager; lead, viewer and the washroom TV see only that it is down');
select is(array[
  pg_temp.val_as('owner',   $$select coalesce(reason, 'null') || ':' || status from public.get_machine_status(pg_temp.id('plantA')) where machine_name = 'Washer 1'$$),
  pg_temp.val_as('manager', $$select coalesce(reason, 'null') || ':' || status from public.get_machine_status(pg_temp.id('plantA')) where machine_name = 'Washer 1'$$),
  pg_temp.val_as('lead',    $$select coalesce(reason, 'null') || ':' || status from public.get_machine_status(pg_temp.id('plantA')) where machine_name = 'Washer 1'$$),
  pg_temp.val_as('viewer',  $$select coalesce(reason, 'null') || ':' || status from public.get_machine_status(pg_temp.id('plantA')) where machine_name = 'Washer 1'$$)],
  array['Ana hurt her hand on the door:down', 'Ana hurt her hand on the door:down', 'null:down', 'null:down'],
  'get_machine_status: reason for owner/manager only');
select ok(pg_temp.val_as('lead', $$select bool_and(since is not null) from public.get_machine_status(pg_temp.id('plantA')) where status = 'down'$$)::boolean,
  'lead still sees since-when (only the free text is hidden)');

-- ══ L1: backdated taps on a washer that is down now ══════════════════════
select is(array[
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), null, pg_temp.id('gMat'), now() - interval '30 seconds')$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), null, pg_temp.id('gMat'), now() - interval '59 seconds')$$)],
  '{MACHINE_DOWN,MACHINE_DOWN}', 'down now: a tap less than 60 s before the down event is refused');
select is(array[
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), null, pg_temp.id('gMat'), now() - interval '60 seconds')$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), null, pg_temp.id('gMat'), now() - interval '10 minutes')$$)],
  '{1,1}', 'down now: a tap at least 60 s before the down event (an offline tap) is recorded');
select is(pg_temp.run_as('lead', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000a3', gen_random_uuid(), null, pg_temp.id('gMat'), now() - interval '30 seconds')$$),
  '1', 'a washer that is up is unaffected');

-- ══ L5: one machine_down alert per machine per 10 minutes ═══════════════
create function pg_temp.alerts(p_machine uuid) returns int language sql stable as $$
  select count(*)::int from public.alert_events a join public.machine_status_events e on e.id = a.subject_id
   where a.kind = 'machine_down' and e.machine_id = p_machine;
$$;
select is(pg_temp.alerts(pg_temp.id('machine')), 1, 'the first down event writes one alert');
select is(array[
  pg_temp.val_as('manager', $$select (public.set_machine_status(pg_temp.id('machine'), 'up', gen_random_uuid())).changed::text$$),
  pg_temp.val_as('manager', $$select (public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), 'Leaking again')).changed::text$$)],
  array['true', 'true'], 'down → up → down within minutes: every change is recorded');
select is(pg_temp.alerts(pg_temp.id('machine')), 1, '… but the flip writes no second alert (cooldown 10 minutes)');
select is((select count(*)::int from public.machine_status_events where machine_id = pg_temp.id('machine') and status = 'down'), 2,
  'both down events are in the history');
select is(pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a3', 'down', gen_random_uuid(), 'Drain')$$), '1',
  'another machine going down …');
select is(pg_temp.alerts('60000000-0000-0000-0000-0000000000a3'), 1, '… gets its own alert (the cooldown is per machine)');
-- 11 minutes later (the earlier alert's sent_at moved back), the next down event notifies again.
update public.alert_events set sent_at = now() - interval '11 minutes' where kind = 'machine_down';
select is(array[
  pg_temp.val_as('owner', $$select (public.set_machine_status(pg_temp.id('machine'), 'up', gen_random_uuid())).changed::text$$),
  pg_temp.val_as('owner', $$select (public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), 'Door')).changed::text$$)],
  array['true', 'true'], 'up, then down again after the cooldown');
select is(pg_temp.alerts(pg_temp.id('machine')), 2, 'after 10 minutes a new down event alerts again');

select * from finish();
rollback;
