-- Owner 2026-11-06: manager on duty = the shift schedule (manager_shift_assignments, managers_on_duty).
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(9);

create function pg_temp.mid(p_user text) returns uuid language sql stable as $$
  select id from public.memberships where user_id = pg_temp.id(p_user) order by created_at, id limit 1;
$$;
grant execute on function pg_temp.mid(text) to authenticated, anon;
-- A second manager, and a shift running now in the spare area.
insert into public.memberships (user_id, org_id, plant_id, role) values (pg_temp.id('nobody'), pg_temp.id('orgA'), pg_temp.id('plantA'), 'manager');
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week, active) values
  ('90000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Now', '00:00', '01:00', '{0}', false);
insert into public.shift_instances (id, org_id, plant_id, area_id, shift_id, business_date, starts_at, ends_at) values
  ('91000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '90000000-0000-0000-0000-0000000000d1', '2000-01-01', now() - interval '1 hour', now() + interval '1 hour');

select is(pg_temp.writes($$insert into public.manager_shift_assignments (org_id, plant_id, membership_id, shift_id)
                            values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.mid('manager'), '90000000-0000-0000-0000-0000000000d1')
                            on conflict (membership_id, shift_id) do nothing$$),
  '{1,42501,42501,42501,42501,42501,42501,42501}', 'assign a manager to a shift: owner only');
select is(pg_temp.run_as('owner', $$insert into public.manager_shift_assignments (org_id, plant_id, membership_id, shift_id)
                                     values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.mid('manager'), pg_temp.id('washNight'))$$),
  '1', 'the same manager also works the washroom night shift');
select is(array[
  pg_temp.run_as('owner', $$insert into public.manager_shift_assignments (org_id, plant_id, membership_id, shift_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.mid('lead'), pg_temp.id('washNight'))$$),
  pg_temp.run_as('owner', $$insert into public.manager_shift_assignments (org_id, plant_id, membership_id, shift_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.mid('ownerB'), pg_temp.id('washNight'))$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED}', 'only active manager memberships of this plant can be assigned');
select is(pg_temp.reads($$select 1 from public.manager_shift_assignments$$), '{2,2,0,0,0,0,0,42501}',
  'reads: owner and managers of the plant');
select is(array(select app.managers_on_duty(pg_temp.id('plantA'), now())), array[pg_temp.id('manager')],
  'the manager assigned to the running shift is on duty now');
select is(array(select app.managers_on_duty(pg_temp.id('plantA'), now() + interval '2 hours')), '{}'::uuid[],
  'nobody when no assigned shift covers that time');
update public.manager_shift_assignments set active = false where shift_id = '90000000-0000-0000-0000-0000000000d1';
select is(array(select app.managers_on_duty(pg_temp.id('plantA'), now())), '{}'::uuid[], 'a deactivated assignment does not count');
select is(pg_temp.run_as('owner', $$delete from public.manager_shift_assignments$$), '42501', 'no deletes (deactivate)');
select is(array[has_function_privilege('authenticated', 'app.managers_on_duty(uuid,timestamptz)', 'execute'),
                has_function_privilege('service_role', 'app.managers_on_duty(uuid,timestamptz)', 'execute')],
  array[false, true], 'managers_on_duty is internal (no per-person reporting through the API)');

select * from finish();
rollback;
