-- Owner 2026-11-06: push delivery for every alert kind (pending/claim_push_notifications) and the
-- washer idle alarm (15 min); plus security re-review notes 2 (display queue history) and 3
-- (managers_on_duty membership re-check).
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(19);

create function pg_temp.k() returns text language sql immutable as $$ select repeat('B', 86) || 'A' $$;
create function pg_temp.a() returns text language sql immutable as $$ select 'abcdefghij_-KLMNOPQRST' $$;
grant execute on function pg_temp.k(), pg_temp.a() to authenticated, anon;

-- The spare area has a shift running now; the manager is on duty there. Washer S lives in it.
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week, active) values
  ('90000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Now', '00:00', '01:00', '{0}', false);
insert into public.shift_instances (id, org_id, plant_id, area_id, shift_id, business_date, starts_at, ends_at) values
  ('91000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '90000000-0000-0000-0000-0000000000d1', '2000-01-01', now() - interval '2 hours', now() + interval '2 hours');
insert into public.memberships (user_id, org_id, plant_id, role) values (pg_temp.id('nobody'), pg_temp.id('orgA'), pg_temp.id('plantA'), 'manager');
insert into public.manager_shift_assignments (org_id, plant_id, membership_id, shift_id)
select pg_temp.id('orgA'), pg_temp.id('plantA'), m.id, '90000000-0000-0000-0000-0000000000d1' from public.memberships m where m.user_id = pg_temp.id('manager');
insert into public.machines (id, org_id, plant_id, area_id, name, kind) values
  ('60000000-0000-0000-0000-0000000000e1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Washer S', 'washer'),
  ('60000000-0000-0000-0000-0000000000e2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Washer T', 'washer');
update public.wash_formulas set cycle_minutes = 30 where id = pg_temp.id('formula');
-- Each washer's last cycle started 60 minutes ago (finished 30 minutes ago); open work waits.
insert into public.washer_cycles (org_id, plant_id, area_id, machine_id, wash_group_id, wash_formula_id, started_at, load_count, source, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '60000000-0000-0000-0000-0000000000e1', pg_temp.id('gNapkin'), pg_temp.id('formula'), now() - interval '60 minutes', 1, 'manual', gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '60000000-0000-0000-0000-0000000000e2', pg_temp.id('gNapkin'), pg_temp.id('formula'), now() - interval '60 minutes', 1, 'manual', gen_random_uuid());
insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), pg_temp.id('gNapkin'), 2, 'load', 1, pg_temp.id('owner'), gen_random_uuid());
select is(pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000e2', 'down', gen_random_uuid(), p_reason_code => 'leaking')$$),
  '1', 'Washer T is down (it must not alarm as idle)');

-- ══ D: washer idle ═══════════════════════════════════════════════════════
select is(app.generate_washer_idle_alerts(), 1, 'Washer S, finished 30 min ago with work waiting during a shift: one alert');
select is(app.generate_washer_idle_alerts(), 0, 'one alert per idle period (no repeat)');
select is((select dedupe_key from public.alert_events where kind = 'washer_idle' and plant_id = pg_temp.id('plantA')),
  (select id::text from public.washer_cycles where machine_id = '60000000-0000-0000-0000-0000000000e1'), 'the idle period is keyed by the finished cycle');
insert into public.washer_cycles (org_id, plant_id, area_id, machine_id, wash_group_id, wash_formula_id, started_at, load_count, source, client_id)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '60000000-0000-0000-0000-0000000000e1', pg_temp.id('gNapkin'), pg_temp.id('formula'), now() - interval '40 minutes', 1, 'manual', gen_random_uuid());
select is(app.generate_washer_idle_alerts(), 0, 'a cycle that finished only 10 minutes ago does not alarm');
update public.washer_cycles set started_at = now() - interval '50 minutes' where started_at = now() - interval '40 minutes';
select is(app.generate_washer_idle_alerts(), 1, 'the next idle period (20 minutes after the newer cycle) alarms again');
update public.queue_items set status = 'cancelled' where area_id = pg_temp.id('spare');
update public.washer_cycles set started_at = now() - interval '70 minutes' where started_at = now() - interval '50 minutes';
update public.washer_cycles set started_at = now() - interval '55 minutes', client_id = gen_random_uuid() where false;
insert into public.washer_cycles (org_id, plant_id, area_id, machine_id, wash_group_id, wash_formula_id, started_at, load_count, source, client_id)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '60000000-0000-0000-0000-0000000000e1', pg_temp.id('gNapkin'), pg_temp.id('formula'), now() - interval '55 minutes', 1, 'manual', gen_random_uuid());
select is(app.generate_washer_idle_alerts(), 0, 'no queued work for the area: no alarm');

-- ══ Generic delivery ═════════════════════════════════════════════════════
select is(array[
  pg_temp.run_as('owner', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/owner', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('manager', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/manager', pg_temp.k(), pg_temp.a())$$),
  pg_temp.run_as('nobody', $$select public.save_push_subscription(pg_temp.id('plantA'), 'https://fcm.googleapis.com/fcm/send/nobody', pg_temp.k(), pg_temp.a())$$)],
  '{1,1,1}', 'owner, the manager on duty and an off-duty manager subscribe');
select is((select array_agg(kind || ':' || right(endpoint, 7) order by kind, endpoint) from app.pending_push_notifications() where plant_id = pg_temp.id('plantA')),
  array['machine_down:/nobody', 'machine_down:d/owner', 'washer_idle:manager', 'washer_idle:manager', 'washer_idle:d/owner', 'washer_idle:d/owner'],
  'machine_down: every owner/manager with alerts on except the manager who marked it down (2026-11-09); washer_idle: owners + the manager on duty only (twice: two idle periods)');
select is((select count(*)::int from app.pending_push_notifications() where kind = 'machine_down' and payload ? 'reason'), 0,
  'payloads never carry the free-text reason');
select is((select payload ->> 'machine_name' || '/' || (payload ->> 'still_idle') from app.pending_push_notifications() where kind = 'washer_idle' and plant_id = pg_temp.id('plantA') order by alert_created limit 1),
  'Washer S/false', 'washer_idle payload: machine name and whether it is still idle');
select set_config('test.claim', (select count(*)::text from public.claim_push_notifications() where plant_id = pg_temp.id('plantA')), true);
select is(current_setting('test.claim')::int, 6, 'claim_push_notifications returns every pending row once');
select is((select count(*)::int from public.claim_push_notifications() where plant_id = pg_temp.id('plantA')), 0, 'a second claim gets nothing (at most once)');
select is(public.mark_push_alert_delivered((select id from public.alert_events where kind = 'washer_idle' and plant_id = pg_temp.id('plantA') order by sent_at, id limit 1), array['x']),
  true, 'mark works for the new kinds');
select is(array[has_function_privilege('authenticated', 'public.claim_push_notifications()', 'execute'),
                has_function_privilege('authenticated', 'public.get_pending_push_notifications()', 'execute'),
                has_function_privilege('authenticated', 'app.generate_washer_idle_alerts()', 'execute'),
                has_function_privilege('service_role', 'public.claim_push_notifications()', 'execute')],
  array[false, false, false, true], 'delivery and generators: service role only');
select is((select command from cron.job where jobname = 'send-alerts'), 'select app.alert_tick()', 'the every-minute job runs the generators, then the dispatch');

-- ══ Re-review note 3: managers_on_duty re-checks the membership ══════════
select is(array(select app.managers_on_duty(pg_temp.id('plantA'), now())), array[pg_temp.id('manager')], 'the manager is on duty');
update public.memberships set plant_id = pg_temp.id('plantA2') where user_id = pg_temp.id('manager');
select is(array(select app.managers_on_duty(pg_temp.id('plantA'), now())), '{}'::uuid[], 'a membership moved to another plant no longer counts');

-- ══ Re-review note 2: displays read open items + the current shift's done items only ══
insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id, status, started_at, completed_at) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gMat'), 1, 'load', 1, pg_temp.id('owner'), gen_random_uuid(), 'queued', null, null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gMat'), 1, 'load', 2, pg_temp.id('owner'), gen_random_uuid(), 'done', '2000-01-01 10:00+00', '2000-01-01 11:00+00');
select is(pg_temp.run_as('display', $$select 1 from public.queue_items where area_id = pg_temp.id('wash')$$, true),
  (select count(*)::text from public.queue_items q where q.area_id = pg_temp.id('wash')
     and (q.status in ('queued', 'in_progress')
          or (q.status = 'done' and exists (select 1 from public.shift_instances si where si.area_id = q.area_id and si.skipped_at is null
                                              and si.starts_at <= now() and si.ends_at > now() and q.completed_at >= si.starts_at and q.completed_at < si.ends_at)))),
  'the washroom display sees open items (and current-shift done items), not old history');

select * from finish();
rollback;
