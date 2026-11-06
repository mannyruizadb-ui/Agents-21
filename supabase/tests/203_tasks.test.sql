-- Owner 2026-11-06 (C): tasks to a named manager or the manager on duty, reminders every 10 minutes
-- until done, done → owners. No per-person stats. Plus security review note 3 (washer idle counts from
-- the later of the cycle's finish and the current shift's start).
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(27);

create function pg_temp.cid(n int) returns uuid language sql immutable as $$
  select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;
$$;
create function pg_temp.t(n int) returns uuid language sql stable as $$ select id from public.tasks where client_id = pg_temp.cid(n) $$;
grant execute on function pg_temp.cid(int), pg_temp.t(int) to authenticated, anon;
-- A second manager; the first manager is on duty (spare-area shift running now).
insert into public.memberships (user_id, org_id, plant_id, role) values (pg_temp.id('nobody'), pg_temp.id('orgA'), pg_temp.id('plantA'), 'manager');
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week, active) values
  ('90000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Now', '00:00', '01:00', '{0}', false);
insert into public.shift_instances (id, org_id, plant_id, area_id, shift_id, business_date, starts_at, ends_at) values
  ('91000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '90000000-0000-0000-0000-0000000000d1', '2000-01-01', now() - interval '10 minutes', now() + interval '2 hours');

-- ══ create_task ══════════════════════════════════════════════════════════
select is(pg_temp.writes($$select public.create_task(pg_temp.id('plantA'), 'Check all parked trucks', gen_random_uuid(), pg_temp.id('nobody'))$$),
  '{1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'create_task: owner only');
select is(array[
  pg_temp.run_as('owner', $$select public.create_task(pg_temp.id('plantA'), 'x', gen_random_uuid(), pg_temp.id('lead'))$$),
  pg_temp.run_as('owner', $$select public.create_task(pg_temp.id('plantA'), 'x', gen_random_uuid(), pg_temp.id('ownerB'))$$),
  pg_temp.run_as('owner', $$select public.create_task(pg_temp.id('plantA'), '   ', gen_random_uuid(), pg_temp.id('manager'))$$),
  pg_temp.run_as('owner', $$select public.create_task(pg_temp.id('plantA'), repeat('x', 201), gen_random_uuid(), pg_temp.id('manager'))$$),
  pg_temp.run_as('owner', $$select public.create_task(pg_temp.id('plantA'), 'x', null, pg_temp.id('manager'))$$),
  pg_temp.run_as('owner', $$select public.create_task(pg_temp.id('plantA'), 'Who is on duty?', gen_random_uuid())$$)],
  array['VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED'],
  'rejects: a lead, another tenant''s user, empty or > 200 characters, no client_id, "on duty" when nobody is on duty');
insert into public.manager_shift_assignments (org_id, plant_id, membership_id, shift_id)
select pg_temp.id('orgA'), pg_temp.id('plantA'), m.id, '90000000-0000-0000-0000-0000000000d1' from public.memberships m where m.user_id = pg_temp.id('manager');
select is(pg_temp.val_as('owner', $$select row((r).to_on_duty, (r).assignee_user_ids, (r).duplicate)::text
                                      from (select public.create_task(pg_temp.id('plantA'), 'Sweep the dock', pg_temp.cid(1)) r) x$$),
  (select row(true, array[pg_temp.id('manager')], false)::text), 'to the manager on duty: resolved to the managers on duty now');
select is(pg_temp.val_as('owner', $$select (public.create_task(pg_temp.id('plantA'), 'Sweep the dock', pg_temp.cid(1))).duplicate::text$$),
  'true', 'idempotent on client_id');
select is((select array[count(*)::text, min(dedupe_key)] from public.alert_events where kind = 'task_assigned' and subject_id = pg_temp.t(1)),
  array['1', '0'], 'task_assigned pushed at once (reminder 0)');

-- ══ Reads ════════════════════════════════════════════════════════════════
select is(pg_temp.reads($$select 1 from public.tasks where plant_id = pg_temp.id('plantA')$$),
  '{2,1,0,0,0,0,0,42501}', 'tasks: the owner sees all; a manager only their own; others nothing');
select is(pg_temp.val_as('nobody', $$select count(*)::text from public.get_tasks(pg_temp.id('plantA'))$$), '1', 'get_tasks: the other manager sees only the task sent to them');
select is(array[pg_temp.run_as('owner', $$select created_by from public.tasks$$), pg_temp.run_as('owner', $$select done_by from public.tasks$$)],
  '{42501,42501}', 'who created or closed a task is never selectable');

-- ══ Reminders every 10 minutes ═══════════════════════════════════════════
select is(app.generate_task_reminders(), 0, 'no reminder before 10 minutes');
update public.alert_events set sent_at = now() - interval '11 minutes' where kind = 'task_assigned' and plant_id = pg_temp.id('plantA');
select is(app.generate_task_reminders(), 2, 'after 10 minutes: one reminder per open task');
select is((select max(dedupe_key) from public.alert_events where kind = 'task_assigned' and subject_id = pg_temp.t(1)), '1', 'reminder 1');
select is(app.generate_task_reminders(), 0, 'no repeat within 10 minutes');

-- ══ Push recipients and payload ══════════════════════════════════════════
select is((select array_agg(distinct u) from public.alert_events a cross join lateral app.alert_recipient_users(a) u
            where a.kind = 'task_assigned' and a.subject_id = pg_temp.t(1)), array[pg_temp.id('manager')], 'task_assigned goes only to the assignee');
select is((select app.alert_payload(a) ->> 'body' from public.alert_events a where a.kind = 'task_assigned' and a.subject_id = pg_temp.t(1) limit 1),
  'Sweep the dock', 'the assignee''s push shows the task text');

-- ══ complete_task ════════════════════════════════════════════════════════
select is(array[
  pg_temp.run_as('nobody', $$select public.complete_task(pg_temp.t(1))$$),
  pg_temp.run_as('lead', $$select public.complete_task(pg_temp.t(1))$$),
  pg_temp.run_as('ownerB', $$select public.complete_task(pg_temp.t(1))$$),
  pg_temp.run_as('ownerB', $$select public.complete_task(gen_random_uuid())$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}', 'only the assignee (or an owner) can close it; no oracle');
select is(pg_temp.run_as('manager', $$select public.complete_task(pg_temp.t(1), repeat('n', 201))$$), 'VALIDATION_FAILED', 'note ≤ 200');
select is(pg_temp.val_as('manager', $$select row((r).done_at is not null, (r).done_note, (r).duplicate)::text from (select public.complete_task(pg_temp.t(1), 'Done, 2 trucks moved') r) x$$),
  '(t,"Done, 2 trucks moved",f)', 'the assignee marks it done with a note');
select is(pg_temp.val_as('manager', $$select (public.complete_task(pg_temp.t(1), 'again')).duplicate::text$$), 'true', 'closing again changes nothing');
select is((select array_agg(distinct u) from public.alert_events a cross join lateral app.alert_recipient_users(a) u
            where a.kind = 'task_done' and a.subject_id = pg_temp.t(1)), array[pg_temp.id('owner')], 'task_done goes to the owners');
select ok(not (select app.alert_payload(a) ? 'done_note' from public.alert_events a where a.kind = 'task_done' and a.subject_id = pg_temp.t(1)),
  'the done note is never in a push payload');
select is((select count(*)::int from public.alert_events a cross join lateral app.alert_recipient_users(a) u
            where a.kind = 'task_assigned' and a.subject_id = pg_temp.t(1)), 0, 'a done task stops reaching the assignee');
update public.alert_events set sent_at = now() - interval '11 minutes' where kind = 'task_assigned' and plant_id = pg_temp.id('plantA');
select is((select count(*)::int from public.alert_events where kind = 'task_assigned' and subject_id = pg_temp.t(1) and dedupe_key = '2'), 0,
  'no more reminders after done') ;
select is(array[
  pg_temp.run_as('owner', $$update public.tasks set body = 'changed' where id = pg_temp.t(1)$$),
  pg_temp.as_service($$update public.tasks set body = 'changed' where id = pg_temp.t(1)$$),
  pg_temp.as_service($$delete from public.tasks where id = pg_temp.t(1)$$)],
  '{42501,VALIDATION_FAILED,VALIDATION_FAILED}', 'no direct writes; a closed task never changes; never deleted');
select is(app.generate_task_reminders(), 1, 'only the open task gets the next reminder');

-- ══ Security review note 3: idle counts from the current shift's start ══
insert into public.machines (id, org_id, plant_id, area_id, name, kind) values
  ('60000000-0000-0000-0000-0000000000e1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Washer S', 'washer');
update public.wash_formulas set cycle_minutes = 30 where id = pg_temp.id('formula');
insert into public.washer_cycles (org_id, plant_id, area_id, machine_id, wash_group_id, wash_formula_id, started_at, load_count, source, client_id)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '60000000-0000-0000-0000-0000000000e1', pg_temp.id('gNapkin'), pg_temp.id('formula'), now() - interval '15 hours', 1, 'manual', gen_random_uuid());
insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), pg_temp.id('gNapkin'), 2, 'load', 1, pg_temp.id('owner'), gen_random_uuid());
select is(app.generate_washer_idle_alerts(), 0, 'the shift started 10 minutes ago: not idle yet, although the last cycle ended last night');
update public.shift_instances set starts_at = now() - interval '20 minutes' where id = '91000000-0000-0000-0000-0000000000d1';
select is(app.generate_washer_idle_alerts(), 1, '20 minutes into the shift: one alarm');
select is((select (app.alert_payload(a) ->> 'idle_since')::timestamptz from public.alert_events a where a.kind = 'washer_idle' and a.plant_id = pg_temp.id('plantA')),
  now() - interval '20 minutes', 'idle_since = the shift start, not last night''s finish');

select * from finish();
rollback;
