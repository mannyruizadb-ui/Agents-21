-- Security review 2026-11-06 (H1, L1): the audit log and crew hours are owner-only, and audit images
-- never carry who entered / created / updated / voided a row.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(6);

insert into public.entry_staff (id, org_id, plant_id, display_name, pin_hash) values
  ('b0000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Ben', extensions.crypt('1470', extensions.gen_salt('bf')));
create function pg_temp.ben() returns uuid language sql as $$
  select (public.start_staff_session('b0000000-0000-0000-0000-0000000000a2', '1470')).staff_session_id;
$$;
grant execute on function pg_temp.ben() to authenticated, anon;
-- Id lookup as the test owner (RLS limits a manager to the current shift, which depends on the wall clock).
create function pg_temp.cycle_of(p_client uuid) returns uuid language sql stable security definer as $$
  select id from public.washer_cycles where client_id = p_client;
$$;
grant execute on function pg_temp.cycle_of(uuid) to authenticated;

-- Activity by the manager: a washer tap and its undo, an estimate, finished goods and a void.
select is(array[
  pg_temp.run_as('manager', $$select public.start_washer_load(pg_temp.id('machine'), 'c0000000-0000-0000-0000-000000000001', null, pg_temp.id('gMat'), p_off_queue_reason => 'other')$$),
  pg_temp.run_as('manager', $$select public.undo_washer_load(pg_temp.cycle_of('c0000000-0000-0000-0000-000000000001'), 'wrong')$$),
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 2, 'load', gen_random_uuid(), pg_temp.ben())$$),
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 3, 'c0000000-0000-0000-0000-000000000002', pg_temp.ben())$$)],
  '{1,1,1,1}', 'the manager taps, undoes, estimates and records finished goods');
select set_config('test.f2', (select id::text from public.finished_goods_entries where client_id = 'c0000000-0000-0000-0000-000000000002'), true);
select is(pg_temp.run_as('owner', $$select public.void_finished_goods(current_setting('test.f2')::uuid, 'typo')$$), '1', 'the owner voids it');

select is(pg_temp.reads($$select 1 from public.audit_log where entity in ('washer_cycles', 'finished_goods_entries', 'soil_estimates') and plant_id = pg_temp.id('plantA')$$),
  array[(select count(*)::text from public.audit_log where entity in ('washer_cycles', 'finished_goods_entries', 'soil_estimates') and plant_id = pg_temp.id('plantA')),
        '0', '0', '0', '0', '0', '0', '42501'],
  'audit_log: the owner reads it; manager, lead, viewer, display and others get 0 rows (anon: no privilege)');
select ok((select count(*) from public.audit_log where entity in ('washer_cycles', 'finished_goods_entries', 'soil_estimates') and plant_id = pg_temp.id('plantA')) >= 5,
  'the activity was audited (insert, void, undo …)');
select is(pg_temp.val_as('owner', $$select count(*)::text from public.audit_log
                                      where plant_id = pg_temp.id('plantA') and entity in ('washer_cycles', 'finished_goods_entries', 'soil_estimates', 'queue_items')
                                        and (coalesce(before, '{}') ?| array['entered_by', 'staff_id', 'created_by', 'voided_by', 'updated_by', 'updated_by_staff_id']
                                             or coalesce(after, '{}') ?| array['entered_by', 'staff_id', 'created_by', 'voided_by', 'updated_by', 'updated_by_staff_id'])$$),
  '0', 'no audit image carries entered_by, staff_id, created_by, voided_by or updated_by (owner: no names anywhere)');

-- L1: crew hours are owner-only.
insert into public.shift_crew_hours (org_id, plant_id, shift_instance_id, area_id, crew_count, labor_hours, entered_by)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03'), pg_temp.id('wash'), 3, 24, pg_temp.id('owner'));
select is(pg_temp.reads($$select 1 from public.shift_crew_hours where plant_id = pg_temp.id('plantA')$$),
  array['1', '0', '0', '0', '0', '0', '0', pg_temp.run_as('anon', $$select 1 from public.shift_crew_hours$$, true)],
  'shift_crew_hours: owner only');

select * from finish();
rollback;
