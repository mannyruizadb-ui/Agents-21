-- Batch review 2026-11-06 notes 2, 3, 5, 6: soil bags are not finished goods; done_by never reaches the
-- audit; route_loaded alerts have a 10-minute cooldown per route and date; only active routes load.
begin;
\ir _fixtures.psql
select plan(7);

create function pg_temp.today() returns date language sql stable as $$ select (now() at time zone 'America/New_York')::date $$;
grant execute on function pg_temp.today() to authenticated, anon;
insert into public.item_types (id, org_id, plant_id, wash_group_id, name, category, count_mode, pack_size, washed) values
  ('70000000-0000-0000-0000-0000000000a9', pg_temp.id('orgA'), pg_temp.id('plantA'), null, 'Soil bags', 'other', 'pack', 5, false);
insert into public.routes (id, org_id, plant_id, name, load_time, days_of_week) values
  ('a1000000-0000-0000-0000-000000000001', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Route Daily', '05:00', '{0,1,2,3,4,5,6}'),
  ('a1000000-0000-0000-0000-000000000002', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Route Old', '05:00', '{0,1,2,3,4,5,6}');
update public.routes set active = false where id = 'a1000000-0000-0000-0000-000000000002';

-- (2)
select is(pg_temp.run_as('owner', $$select public.record_finished_goods('70000000-0000-0000-0000-0000000000a9', 1, 0, gen_random_uuid(), null)$$),
  'VALIDATION_FAILED', '(2) soil bags (never washed) are refused as finished goods with VALIDATION_FAILED');

-- (3)
select is(pg_temp.run_as('owner', $$select public.create_task(pg_temp.id('plantA'), 'Count soil bags', 'c0000000-0000-0000-0000-000000000001', pg_temp.id('manager'))$$), '1', 'a task');
select is(pg_temp.run_as('manager', $$select public.complete_task((select id from public.tasks where client_id = 'c0000000-0000-0000-0000-000000000001'), 'ok')$$), '1', 'done by the manager');
select is((select count(*)::int from public.audit_log where entity = 'tasks' and plant_id = pg_temp.id('plantA')
            and (coalesce(before, '{}') ?| array['done_by', 'created_by'] or after ?| array['done_by', 'created_by'])), 0,
  '(3) no audit image carries done_by or created_by');

-- (5) loaded → not loaded → loaded within 10 minutes: one alert.
select is(array[
  pg_temp.run_as('owner', $$select public.mark_route_loaded('a1000000-0000-0000-0000-000000000001', pg_temp.today(), gen_random_uuid(), true)$$),
  pg_temp.run_as('owner', $$select public.mark_route_loaded('a1000000-0000-0000-0000-000000000001', pg_temp.today(), gen_random_uuid(), false)$$),
  pg_temp.run_as('owner', $$select public.mark_route_loaded('a1000000-0000-0000-0000-000000000001', pg_temp.today(), gen_random_uuid(), true)$$)],
  '{1,1,1}', 'loaded, not loaded, loaded again');
select is(array[(select count(*)::int from public.route_load_events where route_id = 'a1000000-0000-0000-0000-000000000001'),
                (select count(*)::int from public.alert_events where kind = 'route_loaded' and plant_id = pg_temp.id('plantA'))],
  array[3, 1], '(5) three events recorded, one route_loaded alert (10-minute cooldown per route and date)');

-- (6)
select is(pg_temp.run_as('owner', $$select public.mark_route_loaded('a1000000-0000-0000-0000-000000000002', pg_temp.today(), gen_random_uuid())$$),
  'VALIDATION_FAILED', '(6) an inactive route cannot be marked loaded');

select * from finish();
rollback;
