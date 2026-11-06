-- Owner 2026-11-06 (B): routes with weekdays, the daily load-out (owner or granted office manager),
-- copy from another day, "route loaded" by the manager on duty (alerts the owners), and the board.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(27);

-- Dates relative to today (plant-local), on known weekdays: the next Monday and Wednesday from tomorrow.
create function pg_temp.today() returns date language sql stable as $$ select (now() at time zone 'America/New_York')::date $$;
create function pg_temp.next_dow(p int) returns date language sql stable as $$
  select pg_temp.today() + 1 + ((p - extract(dow from pg_temp.today() + 1)::int + 7) % 7);
$$;
grant execute on function pg_temp.today(), pg_temp.next_dow(int) to authenticated, anon;

-- Plant A: Route Mon/Thu, Route Daily, a manager on duty now (spare-area shift), a pack item and soil bags.
insert into public.routes (id, org_id, plant_id, name, load_time, days_of_week, sort_order) values
  ('a1000000-0000-0000-0000-000000000001', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Route 11', '04:30', '{1,4}', 20),
  ('a1000000-0000-0000-0000-000000000002', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Route 2',  '05:00', '{1,2,3,4,5}', 40),
  ('a1000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), 'Route B',  '05:00', '{0,1,2,3,4,5,6}', 10);
insert into public.item_types (id, org_id, plant_id, wash_group_id, name, category, count_mode, pack_size, washed) values
  ('70000000-0000-0000-0000-0000000000a9', pg_temp.id('orgA'), pg_temp.id('plantA'), null, 'Soil bags', 'other', 'pack', 5, false);
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week, active) values
  ('90000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Now', '00:00', '01:00', '{0}', false);
insert into public.shift_instances (org_id, plant_id, area_id, shift_id, business_date, starts_at, ends_at) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '90000000-0000-0000-0000-0000000000d1', '2000-01-01', now() - interval '1 hour', now() + interval '1 hour');
insert into public.manager_shift_assignments (org_id, plant_id, membership_id, shift_id)
select pg_temp.id('orgA'), pg_temp.id('plantA'), m.id, '90000000-0000-0000-0000-0000000000d1' from public.memberships m where m.user_id = pg_temp.id('manager');

-- ══ Routes ═══════════════════════════════════════════════════════════════
select is(pg_temp.reads($$select 1 from public.routes where plant_id = pg_temp.id('plantA')$$), '{2,2,2,2,0,0,0,42501}',
  'routes: every plant role reads; no display, no other tenant');
select is(pg_temp.writes($$update public.routes set load_time = '04:35' where id = 'a1000000-0000-0000-0000-000000000001'$$),
  '{1,0,0,0,0,0,0,42501}', 'routes: owner-only edits');
select is(array[
  pg_temp.as_service($$insert into public.routes (org_id, plant_id, name, load_time, days_of_week) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Bad day', '05:00', '{7}')$$),
  pg_temp.as_service($$insert into public.routes (org_id, plant_id, name, load_time, days_of_week) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'No day', '05:00', '{}')$$)],
  '{23514,23514}', 'weekdays are 0–6 and at least one');
select is((select array_agg(r.name || '@' || to_char(r.load_time, 'HH24:MI') || ':' || array_to_string(r.days_of_week, '') order by r.sort_order)
             from public.routes r join public.plants p on p.id = r.plant_id and p.name = 'Miami'),
  array['Route 21@03:30:1245', 'Route 11@04:30:14', 'Route 5@04:30:25', 'Route 2@05:00:12345', 'Route 4@05:30:1245'],
  'ADB routes: 21 Mon/Tue/Thu/Fri, 11 Mon/Thu, 5 Tue/Fri, 2 Mon–Fri, 4 Mon/Tue/Thu/Fri');
select is((select array[count_mode::text, pack_size::text, washed::text, coalesce(wash_group_id::text, 'null')] from public.item_types i
             join public.plants p on p.id = i.plant_id and p.name = 'Miami' where i.name = 'Soil bags'),
  array['pack', '5', 'false', 'null'], 'ADB soil bags: packs of 5, never washed, no wash group');

-- ══ Entering the load-out ════════════════════════════════════════════════
select is(pg_temp.writes($$select public.set_load_out_line(pg_temp.id('plantA'), pg_temp.next_dow(1), 'a1000000-0000-0000-0000-000000000001', 12, pg_temp.id('napkin'))$$),
  '{1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'set_load_out_line: owner only until granted');
update public.memberships set can_enter_load_out = true where user_id = pg_temp.id('manager');
select is(array[
  pg_temp.run_as('manager', $$select public.set_load_out_line(pg_temp.id('plantA'), pg_temp.next_dow(1), 'a1000000-0000-0000-0000-000000000001', 15, pg_temp.id('napkin'))$$),
  pg_temp.run_as('manager', $$select public.set_load_out_line(pg_temp.id('plantA'), pg_temp.next_dow(1), 'a1000000-0000-0000-0000-000000000001', 4, '70000000-0000-0000-0000-0000000000a9')$$),
  pg_temp.run_as('manager', $$select public.set_load_out_line(pg_temp.id('plantA'), pg_temp.next_dow(1), 'a1000000-0000-0000-0000-000000000002', 6, pg_temp.id('napkin'))$$),
  pg_temp.run_as('manager', $$select public.set_load_out_line(pg_temp.id('plantA'), pg_temp.next_dow(1), 'a1000000-0000-0000-0000-000000000002', 2, null, ' Extra aprons ')$$)],
  '{1,1,1,1}', 'the granted office manager types items, soil bags and a special line');
select is((select qty from public.load_out_lines where route_id = 'a1000000-0000-0000-0000-000000000001' and item_type_id = pg_temp.id('napkin')), 15,
  'the same route + item is updated, not duplicated');
select is(array[
  pg_temp.run_as('owner', $$select public.set_load_out_line(pg_temp.id('plantA'), pg_temp.next_dow(3), 'a1000000-0000-0000-0000-000000000001', 1, pg_temp.id('napkin'))$$),
  pg_temp.run_as('owner', $$select public.set_load_out_line(pg_temp.id('plantA'), pg_temp.next_dow(1), 'a1000000-0000-0000-0000-000000000001', -1, pg_temp.id('napkin'))$$),
  pg_temp.run_as('owner', $$select public.set_load_out_line(pg_temp.id('plantA'), pg_temp.next_dow(1), 'a1000000-0000-0000-0000-000000000001', 1)$$),
  pg_temp.run_as('owner', $$select public.set_load_out_line(pg_temp.id('plantA'), pg_temp.next_dow(1), 'a1000000-0000-0000-0000-000000000001', 1, pg_temp.id('napkin'), 'both')$$),
  pg_temp.run_as('owner', $$select public.set_load_out_line(pg_temp.id('plantA'), pg_temp.next_dow(1), 'a1000000-0000-0000-0000-0000000000b1', 1, pg_temp.id('napkin'))$$),
  pg_temp.run_as('owner', $$select public.set_load_out_line(pg_temp.id('plantA'), pg_temp.next_dow(1), 'a1000000-0000-0000-0000-000000000001', 1, pg_temp.id('itemB'))$$),
  pg_temp.run_as('owner', $$select public.set_load_out_line(pg_temp.id('plantA'), pg_temp.today() + 31, 'a1000000-0000-0000-0000-000000000002', 1, pg_temp.id('napkin'))$$)],
  array['VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED'],
  'rejects: a route on a weekday it does not run, negative qty, neither item nor text, both, another plant''s route or item, > 30 days ahead');
select is(array[
  pg_temp.run_as('ownerB', $$select public.set_load_out_line(pg_temp.id('plantA'), pg_temp.next_dow(1), 'a1000000-0000-0000-0000-000000000001', 1, pg_temp.id('napkin'))$$),
  pg_temp.run_as('owner', $$insert into public.load_out_lines (org_id, plant_id, load_date, route_id, item_type_id, qty) values (pg_temp.id('orgA'), pg_temp.id('plantA'), current_date, 'a1000000-0000-0000-0000-000000000002', pg_temp.id('napkin'), 1)$$)],
  '{NOT_AUTHORIZED,42501}', 'another tenant is refused; no direct writes');

-- ══ The board ════════════════════════════════════════════════════════════
select set_config('test.b', pg_temp.val_as('lead', $$select public.get_load_out_board(pg_temp.id('plantA'), pg_temp.next_dow(1))::text$$), true);
select is((select array_agg(x ->> 'name' order by ord) from jsonb_array_elements(current_setting('test.b')::jsonb -> 'routes') with ordinality as t(x, ord)),
  array['Route 11', 'Route 2'], 'Monday: both routes, by load time');
select is((select array_agg(coalesce(l ->> 'item_name', l ->> 'special_text') || '=' || (l ->> 'qty') order by coalesce(l ->> 'item_name', l ->> 'special_text') || '=' || (l ->> 'qty'))
             from jsonb_array_elements(current_setting('test.b')::jsonb -> 'routes') r, jsonb_array_elements(r -> 'lines') l),
  array['Extra aprons=2', 'Napkin=15', 'Napkin=6', 'Soil bags=4'], 'lines per route, qty in the item''s own count');
select is((select array_agg((t ->> 'item_name') || '=' || (t ->> 'qty') || '/' || (t ->> 'count_mode') order by t ->> 'item_name') from jsonb_array_elements(current_setting('test.b')::jsonb -> 'totals') t),
  array['Napkin=21/pack', 'Soil bags=4/pack'], 'plant totals per item (specials stay on their route)');
select is(pg_temp.val_as('viewer', $$select jsonb_array_length(public.get_load_out_board(pg_temp.id('plantA'), pg_temp.next_dow(3)) -> 'routes')::text$$),
  '1', 'Wednesday shows only the routes that run on Wednesday');
select is(array[pg_temp.run_as('display', $$select public.get_load_out_board(pg_temp.id('plantA'))$$),
                pg_temp.run_as('ownerB', $$select public.get_load_out_board(pg_temp.id('plantA'))$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED}', 'board: plant roles only');
select ok(position('entered_by' in current_setting('test.b')) = 0 and position(pg_temp.id('manager')::text in current_setting('test.b')) = 0,
  'the board names nobody');

-- ══ Copy from another day ════════════════════════════════════════════════
select is(pg_temp.val_as('manager', $$select public.copy_load_out_from(pg_temp.id('plantA'), pg_temp.next_dow(1), pg_temp.next_dow(1) + 7)::text$$),
  '4', 'copy Monday to next Monday: 4 lines');
select is(pg_temp.val_as('manager', $$select public.copy_load_out_from(pg_temp.id('plantA'), pg_temp.next_dow(1), pg_temp.next_dow(1) + 7)::text$$),
  '0', 'copying again changes nothing (existing lines are never overwritten)');
select is(pg_temp.val_as('owner', $$select public.copy_load_out_from(pg_temp.id('plantA'), pg_temp.next_dow(1), pg_temp.next_dow(1) + 2)::text$$),
  '2', 'copy Monday to Wednesday: only Route 2 runs, 2 lines');
select is(pg_temp.run_as('lead', $$select public.copy_load_out_from(pg_temp.id('plantA'), pg_temp.next_dow(1), pg_temp.next_dow(1) + 14)$$),
  'NOT_AUTHORIZED', 'copy: owner or granted manager only');

-- ══ Route loaded ═════════════════════════════════════════════════════════
select is(pg_temp.writes($$select public.mark_route_loaded('a1000000-0000-0000-0000-000000000002', pg_temp.today() + (case when extract(dow from pg_temp.today()) between 1 and 5 then 0 when extract(dow from pg_temp.today()) = 6 then -1 else 1 end), gen_random_uuid())$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'mark_route_loaded: an owner or the manager on duty (the second call records nothing new)');
select is((select count(*)::int from public.alert_events where kind = 'route_loaded' and plant_id = pg_temp.id('plantA')), 1,
  'one route_loaded alert for the owners');
delete from public.manager_shift_assignments where false;
update public.manager_shift_assignments set active = false;
select is(pg_temp.run_as('manager', $$select public.mark_route_loaded('a1000000-0000-0000-0000-000000000002', pg_temp.today() + (case when extract(dow from pg_temp.today()) between 1 and 5 then 0 when extract(dow from pg_temp.today()) = 6 then -1 else 1 end), gen_random_uuid(), false)$$),
  'NOT_AUTHORIZED', 'a manager who is not on duty cannot mark routes');
select is(pg_temp.run_as('owner', $$select public.mark_route_loaded('a1000000-0000-0000-0000-000000000001', pg_temp.today() + 20, gen_random_uuid())$$),
  'VALIDATION_FAILED', 'only yesterday, today or tomorrow');
select is((select count(*)::int from app.pending_push_notifications() where kind = 'route_loaded' and plant_id = pg_temp.id('plantA')), 0,
  'no subscription yet: nothing pending for delivery');
select is((select app.alert_payload(a) ->> 'route_name' from public.alert_events a where a.kind = 'route_loaded' limit 1), 'Route 2',
  'route_loaded payload: the route name (no names of people)');
select is(pg_temp.run_as('owner', $$select entered_by from public.route_load_events$$), '42501', 'who marked it is never readable');

select * from finish();
rollback;
