-- Owner 2026-11-06 (B): clearing alerts in the Alerts tab. Per person, RPC-only, append-only; only the
-- caller's own alerts and only finished ones (a live alert cannot be cleared); no oracle for others'.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(25);

-- Alert ids by kind, remembered (as the service role) once the alerts exist: clients cannot read alert_events.
create function pg_temp.remember() returns void language sql as $$
  select set_config('test.' || kind, id::text, true) from public.alert_events
   where plant_id = pg_temp.id('plantA') and kind = any (app.push_alert_kinds())
     and (kind = 'washer_idle' or coalesce(dedupe_key, '0') = '0');   -- task_assigned: the first one (listed once per task)
$$;
create function pg_temp.a(p_kind text) returns uuid language sql stable as $$
  select nullif(current_setting('test.' || p_kind, true), '')::uuid;
$$;
grant execute on function pg_temp.a(text) to authenticated, anon;
create function pg_temp.kinds(p_user text) returns text language sql as $$
  select pg_temp.val_as(p_user, $q$select coalesce(string_agg(kind, ',' order by kind), '-') from public.get_my_alerts(pg_temp.id('plantA'))$q$);
$$;
create function pg_temp.clear(p_user text, p_kinds text[]) returns text language sql as $$
  select pg_temp.val_as(p_user, format($q$with c as (select alert_id from public.clear_my_alerts(pg_temp.id('plantA'), array(select pg_temp.a(k) from unnest(%1$L::text[]) k)))
      select coalesce(string_agg(k, ',' order by k), '-') from unnest(%1$L::text[]) k where pg_temp.a(k) in (select alert_id from c)$q$, p_kinds));
$$;
-- The manager is on duty (spare-area shift running now).
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week, active) values
  ('90000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Now', '00:00', '01:00', '{0}', false);
insert into public.shift_instances (org_id, plant_id, area_id, shift_id, business_date, starts_at, ends_at) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '90000000-0000-0000-0000-0000000000d1', '2000-01-01', now() - interval '2 hours', now() + interval '2 hours');
insert into public.manager_shift_assignments (org_id, plant_id, membership_id, shift_id)
select pg_temp.id('orgA'), pg_temp.id('plantA'), m.id, '90000000-0000-0000-0000-0000000000d1' from public.memberships m where m.user_id = pg_temp.id('manager');

-- Alerts: Washer 1 down (machine_down), Washer S idle (washer_idle), a route loaded (route_loaded), a
-- task to the manager, done (task_done, awaiting review).
select is(pg_temp.run_as('manager', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), null, 'leaking')$$), '1', 'Washer 1 down');
insert into public.machines (id, org_id, plant_id, area_id, name, kind) values
  ('60000000-0000-0000-0000-0000000000e1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Washer S', 'washer');
update public.wash_formulas set cycle_minutes = 30 where id = pg_temp.id('formula');
insert into public.washer_cycles (org_id, plant_id, area_id, machine_id, wash_group_id, wash_formula_id, started_at, load_count, source, client_id)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '60000000-0000-0000-0000-0000000000e1', pg_temp.id('gNapkin'), pg_temp.id('formula'), now() - interval '60 minutes', 1, 'manual', gen_random_uuid());
insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), pg_temp.id('gNapkin'), 2, 'load', 1, pg_temp.id('owner'), gen_random_uuid());
select is(app.generate_washer_idle_alerts(), 1, 'Washer S idle');
insert into public.routes (id, org_id, plant_id, name, load_time, days_of_week) values
  ('a1000000-0000-0000-0000-000000000001', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Route Daily', '05:00', '{0,1,2,3,4,5,6}');
select is(pg_temp.run_as('owner', $$select public.mark_route_loaded('a1000000-0000-0000-0000-000000000001', (now() at time zone 'America/New_York')::date, gen_random_uuid())$$), '1', 'a route loaded');
select is(pg_temp.run_as('owner', $$select public.create_task(pg_temp.id('plantA'), 'Move the trucks', 'c0000000-0000-0000-0000-000000000001', pg_temp.id('manager'))$$), '1', 'a task to the manager');
select is(pg_temp.run_as('manager', $$select public.complete_task((select id from public.tasks where client_id = 'c0000000-0000-0000-0000-000000000001'))$$), '1', 'done');
select is(array[pg_temp.kinds('owner'), pg_temp.kinds('manager')],
  array['machine_down,route_loaded,task_done,washer_idle', 'machine_down,task_assigned,washer_idle'], 'before clearing');
select pg_temp.remember();
select is(pg_temp.val_as('owner', $$select string_agg(kind || '=' || can_clear, ',' order by kind) from public.get_my_alerts(pg_temp.id('plantA'))$$),
  'machine_down=false,route_loaded=true,task_done=false,washer_idle=false', 'can_clear: live alerts no; route_loaded (informational) yes');

-- ══ Roles ════════════════════════════════════════════════════════════════
select is(pg_temp.writes($$select * from public.clear_my_alerts(pg_temp.id('plantA'), array[pg_temp.a('route_loaded')])$$),
  '{1,0,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'clear_my_alerts: owner/manager only; the manager does not receive route_loaded, so it is skipped; other tenant refused');
select is(pg_temp.writes($$select public.clear_my_finished_alerts(pg_temp.id('plantA'))$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'clear_my_finished_alerts: owner/manager only; other tenant refused');
select is(array[pg_temp.kinds('owner'), pg_temp.kinds('manager')],
  array['machine_down,task_done,washer_idle', 'machine_down,washer_idle'],
  'the owner''s route_loaded and the manager''s finished task_assigned are cleared; live ones stay');
select is(pg_temp.val_as('ownerB', $$select count(*)::text from public.clear_my_alerts(pg_temp.id('plantB'), array[pg_temp.a('machine_down'), pg_temp.a('task_done')])$$),
  '0', 'cross-tenant: another plant''s alert ids are skipped silently (no oracle)');
select is(array[
  pg_temp.run_as('owner', $$select * from public.clear_my_alerts(pg_temp.id('plantA'), '{}')$$),
  pg_temp.run_as('owner', $$select * from public.clear_my_alerts(pg_temp.id('plantA'), null)$$),
  pg_temp.run_as('owner', $$select * from public.clear_my_alerts(pg_temp.id('plantA'), array[null::uuid])$$),
  pg_temp.run_as('owner', $$select * from public.clear_my_alerts(pg_temp.id('plantA'), array(select gen_random_uuid() from generate_series(1, 201)))$$),
  pg_temp.run_as('owner', $$select * from public.clear_my_alerts(pg_temp.id('plantA'), array[gen_random_uuid()])$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,0}', 'p_alert_ids: 1–200, no nulls; unknown ids skipped');

-- ══ A live alert cannot be cleared ═══════════════════════════════════════
select is(pg_temp.clear('owner', array['machine_down', 'washer_idle', 'task_done']), '-',
  'machine still down, washer still idle, task awaiting review: nothing cleared');
select is(pg_temp.kinds('owner'), 'machine_down,task_done,washer_idle', 'still listed');

-- ══ Per person ═══════════════════════════════════════════════════════════
select is(pg_temp.run_as('manager', $$select public.set_machine_status(pg_temp.id('machine'), 'up', gen_random_uuid())$$), '1', 'Washer 1 fixed');
select is(pg_temp.clear('owner', array['machine_down']), 'machine_down', 'the owner clears the finished machine_down');
select is(array[pg_temp.kinds('owner'), pg_temp.kinds('manager')],
  array['task_done,washer_idle', 'machine_down,washer_idle'], 'cleared only for the owner: the manager still has it');
select is(array[pg_temp.val_as('owner', $$select public.get_my_alert_count(pg_temp.id('plantA'))::text$$),
                pg_temp.val_as('manager', $$select public.get_my_alert_count(pg_temp.id('plantA'))::text$$)],
  array['2', '2'], 'badge counts leave out the caller''s own cleared alerts only');
select is(pg_temp.clear('owner', array['machine_down']), 'machine_down', 'clearing again is idempotent');
select is((select count(*)::int from public.alert_dismissals), 3, 'one row per (person, alert)');
select is(pg_temp.clear('manager', array['machine_down']), 'machine_down', 'the manager clears their own copy');

-- ══ Review finishes the task_done alert ══════════════════════════════════
select is(pg_temp.run_as('owner', $$select public.review_task((select id from public.tasks where client_id = 'c0000000-0000-0000-0000-000000000001'))$$), '1', 'reviewed');
select is(array[pg_temp.val_as('owner', $$select public.clear_my_finished_alerts(pg_temp.id('plantA'))::text$$), pg_temp.kinds('owner')],
  array['1', 'washer_idle'], 'clear all finished: the reviewed task_done goes; the idle washer stays');

-- ══ RPC-only, append-only ════════════════════════════════════════════════
select is(array[
  pg_temp.run_as('owner', $$select 1 from public.alert_dismissals$$, true),
  pg_temp.run_as('owner', $$insert into public.alert_dismissals (org_id, plant_id, alert_id, user_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.a('washer_idle'), pg_temp.id('owner'))$$),
  pg_temp.as_service($$update public.alert_dismissals set dismissed_at = now()$$),
  pg_temp.as_service($$delete from public.alert_dismissals$$),
  pg_temp.as_service($$truncate public.alert_dismissals$$)],
  '{42501,42501,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}', 'no client reads or writes; never updated, deleted or truncated');
select is(pg_temp.as_service($$insert into public.alert_dismissals (org_id, plant_id, alert_id, user_id)
                               select pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.a('washer_idle'), pg_temp.id('ownerB')$$),
  '23503', 'composite FK: a dismissal cannot point at another tenant''s alert');

select * from finish();
rollback;
