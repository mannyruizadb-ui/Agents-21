-- No alerts for your own actions (owner 2026-11-09; 20261109215631_exclude_actor_from_alerts): the account whose
-- action raised an alert is neither a push recipient nor shown it in the Alerts tab / badge, for every kind with
-- an actor (machine_down, route_loaded, task_assigned, task_done, customer_delivery, estimate_entered,
-- rewash_added); system kinds (washer_idle, task reminders) keep everyone; the actor is never exposed.
begin;
\ir _fixtures.psql
select plan(24);

-- A second owner of plant A (ownerP) so every owner-only kind still has someone to tell.
insert into public.memberships (user_id, org_id, plant_id, role) values (pg_temp.id('ownerP'), pg_temp.id('orgA'), pg_temp.id('plantA'), 'owner');
update public.memberships set notify_machine_down = true
 where user_id in (pg_temp.id('owner'), pg_temp.id('manager'), pg_temp.id('ownerP'));
-- The manager is on duty (spare-area shift running now), for route_loaded.
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week, active) values
  ('90000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Now', '00:00', '01:00', '{0}', false);
insert into public.shift_instances (org_id, plant_id, area_id, shift_id, business_date, starts_at, ends_at) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '90000000-0000-0000-0000-0000000000d1', '2000-01-01', now() - interval '2 hours', now() + interval '2 hours');
insert into public.manager_shift_assignments (org_id, plant_id, membership_id, shift_id)
select pg_temp.id('orgA'), pg_temp.id('plantA'), m.id, '90000000-0000-0000-0000-0000000000d1' from public.memberships m where m.user_id = pg_temp.id('manager');
insert into public.routes (id, org_id, plant_id, name, load_time, days_of_week) values
  ('a1000000-0000-0000-0000-000000000001', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Route Daily', '05:00', '{0,1,2,3,4,5,6}');
insert into public.customers (id, org_id, plant_id, name) values
  ('c1000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'AA Test');
insert into public.wash_groups (id, org_id, plant_id, customer_id, name, loads_per_bin, allow_bin_estimates) values
  ('71000000-0000-0000-0000-0000000aa0a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1', 'Kitchen towels', 1.5, true);

-- One alert of a kind, as the service role (clients cannot read alert_events).
create function pg_temp.alert(p_kind text) returns public.alert_events language sql stable as $$
  select a from public.alert_events a where a.plant_id = pg_temp.id('plantA') and a.kind = p_kind order by a.sent_at desc, a.id desc limit 1;
$$;
-- Push recipients of the latest alert of a kind, as fixture names.
create function pg_temp.to(p_kind text) returns text language sql stable as $$
  select coalesce(string_agg(n, ',' order by n), '-') from (
    select case u when pg_temp.id('owner') then 'owner' when pg_temp.id('ownerP') then 'ownerP'
                  when pg_temp.id('manager') then 'manager' else u::text end as n
      from app.alert_recipient_users(pg_temp.alert(p_kind)) u) x;
$$;
-- Whether p_user sees the latest alert of a kind in their Alerts tab.
create function pg_temp.sees(p_user text, p_kind text) returns text language sql as $$
  select pg_temp.val_as(p_user, format($q$select (count(*) > 0)::text from public.get_my_alerts(pg_temp.id('plantA')) where alert_id = %L$q$,
                                       (pg_temp.alert(p_kind)).id));
$$;

-- ══ machine_down ═════════════════════════════════════════════════════════
select is(pg_temp.run_as('owner', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), null, 'leaking')$$), '1',
  'the owner marks Washer 1 down');
select is(pg_temp.to('machine_down'), 'manager,ownerP', 'push: everyone with machine-down alerts on, except the owner who marked it');
select is(array[pg_temp.sees('owner', 'machine_down'), pg_temp.sees('manager', 'machine_down'), pg_temp.sees('ownerP', 'machine_down')],
  '{false,true,true}', 'Alerts tab: not for the owner who did it; the manager and the other owner see it');
select is(array[pg_temp.val_as('owner', $$select public.get_my_alert_count(pg_temp.id('plantA'))::text$$),
                pg_temp.val_as('manager', $$select public.get_my_alert_count(pg_temp.id('plantA'))::text$$)],
  '{0,1}', 'the badge leaves it out for the actor only');
select is(pg_temp.val_as('owner', format($$select count(*)::text from public.clear_my_alerts(pg_temp.id('plantA'), array[%L::uuid])$$, (pg_temp.alert('machine_down')).id)),
  '0', 'the actor cannot clear it either (not theirs)');

-- ══ route_loaded ═════════════════════════════════════════════════════════
select is(pg_temp.run_as('owner', $$select public.mark_route_loaded('a1000000-0000-0000-0000-000000000001', (now() at time zone 'America/New_York')::date, gen_random_uuid())$$), '1',
  'the owner marks a route loaded');
select is(array[pg_temp.to('route_loaded'), pg_temp.sees('owner', 'route_loaded'), pg_temp.sees('ownerP', 'route_loaded')],
  '{ownerP,false,true}', 'route_loaded: only the other owner');

-- ══ tasks ════════════════════════════════════════════════════════════════
select is(pg_temp.run_as('owner', $$select public.create_task(pg_temp.id('plantA'), 'Call the boiler tech', 'c0000000-0000-0000-0000-000000000001', pg_temp.id('manager'))$$), '1',
  'the owner writes a task to the manager (tasks go to managers only)');
select is(array[pg_temp.to('task_assigned'), coalesce((app.alert_actor(pg_temp.alert('task_assigned')) = pg_temp.id('owner'))::text, 'none')], '{manager,true}',
  'task_assigned: its actor is the writer (excluded if they were ever an assignee); the manager is told');
update public.alert_events set sent_at = now() - interval '11 minutes' where kind = 'task_assigned';
select is(app.generate_task_reminders(), 1, 'a reminder (written by the system) …');
select is(array[pg_temp.to('task_assigned'), coalesce(app.alert_actor(pg_temp.alert('task_assigned'))::text, 'none')], '{manager,none}',
  '… has no actor, so it reaches every assignee');
select is(pg_temp.run_as('owner', $$select public.complete_task((select id from public.tasks where client_id = 'c0000000-0000-0000-0000-000000000001'), null)$$), '1',
  'the owner marks it done (owners may)');
select is(array[pg_temp.to('task_done'), pg_temp.sees('owner', 'task_done'), pg_temp.sees('ownerP', 'task_done')],
  '{ownerP,false,true}', 'task_done: told to the other owner only');
-- Age the first task_done so "latest" is deterministic (both would share now() and tie-break on a random id).
update public.alert_events set sent_at = sent_at - interval '1 minute' where kind = 'task_done';
select is(pg_temp.run_as('owner', $$select public.create_task(pg_temp.id('plantA'), 'Count the bins', 'c0000000-0000-0000-0000-000000000002', pg_temp.id('manager'))$$)
       || '/' || pg_temp.run_as('manager', $$select public.complete_task((select id from public.tasks where client_id = 'c0000000-0000-0000-0000-000000000002'), null)$$),
  '1/1', 'a task to the manager, done by the manager …');
select is(array[pg_temp.to('task_done'), pg_temp.sees('owner', 'task_done')], '{"owner,ownerP",true}',
  '… reaches both owners (the actor is the manager)');

-- ══ Owner information kinds ══════════════════════════════════════════════
select is(pg_temp.run_as('owner', $$select public.record_customer_delivery(pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1',
                                      '[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":2}]', gen_random_uuid(), null)$$), '1',
  'the owner records an AA drop-off');
select is(array[(pg_temp.alert('customer_delivery')).recipients::text, pg_temp.to('customer_delivery'),
                pg_temp.sees('owner', 'customer_delivery'), pg_temp.sees('ownerP', 'customer_delivery')],
  '{"{}",ownerP,false,true}', 'customer_delivery: pending push for the other owner (push by default); not for the actor');
select is(pg_temp.run_as('owner', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 2, 'load', gen_random_uuid(), null)$$), '1',
  'the owner enters an estimate');
select is(array[pg_temp.sees('owner', 'estimate_entered'), pg_temp.sees('ownerP', 'estimate_entered')], '{false,true}',
  'estimate_entered (quiet by default): the other owner''s Alerts tab only');
select is(pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gTowel'), p_is_rewash => true)$$), '1',
  'a manager adds a rewash');
select is(array[app.alert_actor(pg_temp.alert('rewash_added')) = pg_temp.id('manager'), pg_temp.sees('owner', 'rewash_added') = 'true'],
  array[true, true], 'rewash_added: the actor is the manager (never an owner recipient), so the owners still see it');

-- raise_owner_alert decides push vs quiet with the SAME actor as push/visibility (the subject row), not the
-- caller: raised here with no caller at all (postgres), for the owner's own drop-off, while the other owner
-- keeps customer_delivery quiet → nobody to push to → '{quiet}' (the caller-based rule said '{}').
update public.memberships set alert_levels = coalesce(alert_levels, '{}'::jsonb) || '{"customer_delivery":"quiet"}'
 where user_id = pg_temp.id('ownerP');
select set_config('test.raised', app.raise_owner_alert(pg_temp.id('orgA'), pg_temp.id('plantA'), 'customer_delivery',
                    (select d.id from public.customer_deliveries d where d.plant_id = pg_temp.id('plantA') limit 1), 'actor-check')::text, true);
select is((select a.recipients::text from public.alert_events a where a.id = current_setting('test.raised')::uuid),
  '{quiet}', 'raise_owner_alert: the actor comes from the subject row (no push owner left besides the actor → quiet)');
select is(array[has_function_privilege('service_role', 'app.pending_machine_down_alerts()', 'execute'),
                has_function_privilege('service_role', 'app.claim_machine_down_alerts()', 'execute'),
                has_function_privilege('service_role', 'public.get_pending_push_alerts()', 'execute'),
                has_function_privilege('service_role', 'public.claim_push_alerts()', 'execute')],
  array[false, false, false, false], 'the legacy machine-down push helpers (no actor rule) are no longer callable by the service role');

-- ══ Nothing leaks ════════════════════════════════════════════════════════
select is(array[has_function_privilege('authenticated', 'app.alert_actor(public.alert_events)', 'execute'),
                has_function_privilege('authenticated', 'app.alert_audience(public.alert_events)', 'execute'),
                has_function_privilege('anon', 'app.alert_actor(public.alert_events)', 'execute'),
                (select count(*) = 0 from public.alert_events a
                  where a.plant_id = pg_temp.id('plantA')
                    and app.alert_payload(a)::text ~ ('(' || pg_temp.id('owner') || '|' || pg_temp.id('manager') || ')'))],
  array[false, false, false, true], 'the actor helpers are internal, and no payload carries the actor''s id');

select * from finish();
rollback;
