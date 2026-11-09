-- Alerts tab (2026-11-06): get_my_alerts / get_my_alert_count show each owner / manager the alerts they
-- would receive by push, with the same payload rules.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(15);

create function pg_temp.kinds(p_user text) returns text language sql as $$
  select pg_temp.val_as(p_user, $q$select string_agg(kind, ',' order by kind) from public.get_my_alerts(pg_temp.id('plantA'))$q$);
$$;
-- A second manager ("nobody"), not on duty, alerts off; the manager is on duty in the spare area.
insert into public.memberships (user_id, org_id, plant_id, role, notify_machine_down) values (pg_temp.id('nobody'), pg_temp.id('orgA'), pg_temp.id('plantA'), 'manager', false);
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week, active) values
  ('90000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Now', '00:00', '01:00', '{0}', false);
insert into public.shift_instances (org_id, plant_id, area_id, shift_id, business_date, starts_at, ends_at) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '90000000-0000-0000-0000-0000000000d1', '2000-01-01', now() - interval '2 hours', now() + interval '2 hours');
insert into public.manager_shift_assignments (org_id, plant_id, membership_id, shift_id)
select pg_temp.id('orgA'), pg_temp.id('plantA'), m.id, '90000000-0000-0000-0000-0000000000d1' from public.memberships m where m.user_id = pg_temp.id('manager');

-- Alerts: Washer 1 down (machine_down), Washer S idle (washer_idle), a task to "nobody" with a reminder,
-- done (task_done), and a route loaded (route_loaded).
-- 2026-11-09: nobody gets an alert for their own action, so the down and the route are someone else's.
select is(pg_temp.run_as('nobody', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), 'Ana: secret', 'leaking')$$), '1', 'Washer 1 down (by the other manager)');
insert into public.machines (id, org_id, plant_id, area_id, name, kind) values
  ('60000000-0000-0000-0000-0000000000e1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Washer S', 'washer');
update public.wash_formulas set cycle_minutes = 30 where id = pg_temp.id('formula');
insert into public.washer_cycles (org_id, plant_id, area_id, machine_id, wash_group_id, wash_formula_id, started_at, load_count, source, client_id)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '60000000-0000-0000-0000-0000000000e1', pg_temp.id('gNapkin'), pg_temp.id('formula'), now() - interval '60 minutes', 1, 'manual', gen_random_uuid());
insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), pg_temp.id('gNapkin'), 2, 'load', 1, pg_temp.id('owner'), gen_random_uuid());
select is(app.generate_washer_idle_alerts(), 1, 'Washer S idle');
select is(pg_temp.run_as('owner', $$select public.create_task(pg_temp.id('plantA'), 'Move the parked trucks', 'c0000000-0000-0000-0000-000000000001', pg_temp.id('nobody'))$$), '1', 'a task to the other manager');
update public.alert_events set sent_at = now() - interval '11 minutes' where kind = 'task_assigned';
select is(app.generate_task_reminders(), 1, 'one reminder');
insert into public.routes (id, org_id, plant_id, name, load_time, days_of_week) values
  ('a1000000-0000-0000-0000-000000000001', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Route Daily', '05:00', '{0,1,2,3,4,5,6}');
select is(pg_temp.run_as('manager', $$select public.mark_route_loaded('a1000000-0000-0000-0000-000000000001', (now() at time zone 'America/New_York')::date, gen_random_uuid())$$), '1', 'a route loaded (by the manager on duty)');

-- ══ Who sees what ════════════════════════════════════════════════════════
select is(array[pg_temp.kinds('owner'), pg_temp.kinds('manager'), pg_temp.kinds('nobody')],
  array['machine_down,route_loaded,washer_idle', 'machine_down,washer_idle', 'task_assigned'],
  'owner: down, idle, route; the manager on duty: down, idle; the other manager (alerts off, not on duty): only their task, once');
select is(pg_temp.run_as('nobody', $$select public.complete_task((select id from public.tasks where client_id = 'c0000000-0000-0000-0000-000000000001'), 'moved')$$), '1', 'the task is done');
select is(array[pg_temp.kinds('owner'), pg_temp.kinds('nobody')],
  array['machine_down,route_loaded,task_done,washer_idle', 'task_assigned'], 'task_done reaches the owners; the assignee keeps their task row');
select is(pg_temp.writes($$select * from public.get_my_alerts(pg_temp.id('plantA'))$$),
  '{4,2,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'get_my_alerts: owners and managers only; other tenant refused');

-- ══ Payloads and state ═══════════════════════════════════════════════════
select is(pg_temp.val_as('nobody', $$select (payload ->> 'body') || '/' || still_current from public.get_my_alerts(pg_temp.id('plantA'))$$),
  'Move the parked trucks/false', 'the assignee sees the task text; done → no longer current');
select is(pg_temp.val_as('owner', $$select count(*)::text from public.get_my_alerts(pg_temp.id('plantA')) where payload ? 'reason' or payload ? 'done_note' or payload::text like '%Ana%'$$),
  '0', 'no free-text reason, done note or names in any payload');
select is(pg_temp.val_as('owner', $$select string_agg(kind || '=' || still_current, ',' order by kind) from public.get_my_alerts(pg_temp.id('plantA'))$$),
  'machine_down=true,route_loaded=true,task_done=true,washer_idle=true', 'still_current: down, loaded, idle are still true; task_done stays live until an owner reviews it (owner 2026-11-06)');

-- ══ Window and badge ═════════════════════════════════════════════════════
update public.alert_events set sent_at = now() - interval '2 days' where kind = 'route_loaded';
update public.alert_events set sent_at = now() - interval '8 days' where kind = 'washer_idle';
select is(array[pg_temp.kinds('owner'), pg_temp.val_as('owner', $$select public.get_my_alert_count(pg_temp.id('plantA'))::text$$)],
  array['machine_down,route_loaded,task_done', '2'], 'the list covers 7 days; the badge counts the last 24 hours');
select is(array[pg_temp.run_as('owner', $$select * from public.get_my_alerts(pg_temp.id('plantA'), 0)$$),
                pg_temp.run_as('lead', $$select public.get_my_alert_count(pg_temp.id('plantA'))$$),
                pg_temp.run_as('ownerB', $$select public.get_my_alert_count(pg_temp.id('plantA'))$$)],
  '{VALIDATION_FAILED,NOT_AUTHORIZED,NOT_AUTHORIZED}', 'p_limit 1–200; the badge is owner/manager only, no cross-tenant');

-- ══ p_since (badge since the tab was last opened) ════════════════════════
select is(array[
  pg_temp.val_as('owner', $$select public.get_my_alert_count(pg_temp.id('plantA'), now() - interval '3 days')::text$$),
  pg_temp.val_as('owner', $$select public.get_my_alert_count(pg_temp.id('plantA'), now() - interval '1 hour')::text$$),
  pg_temp.val_as('owner', $$select public.get_my_alert_count(pg_temp.id('plantA'), now() - interval '30 days')::text$$),
  pg_temp.val_as('owner', $$select public.get_my_alert_count(p_plant_id => pg_temp.id('plantA'))::text$$)],
  array['3', '2', '3', '2'],
  'p_since: 3 days back counts the 2-day-old route too; 1 hour back only today''s; never beyond 7 days (the 8-day idle alert); no p_since = 24 h');

select * from finish();
rollback;
