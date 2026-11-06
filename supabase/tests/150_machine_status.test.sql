-- Machine down / up (owner 2026-11-04): machine_status_events (append-only), set_machine_status,
-- get_machine_status, the machine_down push hook in alert_events, and what a down washer does to
-- start_washer_load (MACHINE_DOWN), queue assignment and get_washroom_board. Also start_washer_load's
-- p_tapped_at (offline taps): window, shift / production-day resolution, idempotency, undo.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(44);

-- Washer 1 (fixture) and Washer 3 in washroom A; Washer 5 inactive; Dryer 1; Ironer M in finishing;
-- Washer B in plant B; Washer A2 in plant A2 (its own shift, below).
insert into public.machines (id, org_id, plant_id, area_id, name, kind, active) values
  ('60000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 3', 'washer', true),
  ('60000000-0000-0000-0000-0000000000a5', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 5', 'washer', false),
  ('60000000-0000-0000-0000-0000000000a4', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Dryer 1', 'dryer', true),
  ('60000000-0000-0000-0000-0000000000a6', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), 'Ironer M', 'ironer', true),
  ('60000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), 'Washer B', 'washer', true),
  ('60000000-0000-0000-0000-0000000000c1', pg_temp.id('orgA'), pg_temp.id('plantA2'), pg_temp.id('washA2'), 'Washer A2', 'washer', true);

create function pg_temp.cid(n int) returns uuid language sql immutable as $$
  select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;
$$;
create function pg_temp.cyc(n int) returns uuid language sql stable as $$
  select id from public.washer_cycles where client_id = pg_temp.cid(n);
$$;
grant execute on function pg_temp.cid(int), pg_temp.cyc(int) to authenticated, anon;

-- ══ set_machine_status ═══════════════════════════════════════════════════
select is(pg_temp.writes($$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), 'Door latch broken')$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'set_machine_status: owner/manager only (lead, viewer, display, other tenant: NOT_AUTHORIZED; anon: no EXECUTE)');
select is((select array[count(*)::text, min(reason), min(entered_by::text)] from public.machine_status_events where machine_id = pg_temp.id('machine')),
  array['1', 'Door latch broken', pg_temp.id('owner')::text], 'one down event (the manager''s second "down" changed nothing)');
select is((select array[count(*)::text, min(recipients::text)] from public.alert_events
            where kind = 'machine_down' and subject_id = (select id from public.machine_status_events where machine_id = pg_temp.id('machine'))),
  array['1', '{}'], 'push hook: one undelivered machine_down alert per down event (subject = the event)');
select is(pg_temp.val_as('manager', $$select (public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), 'again')).changed$$),
  'false', 'already down: changed = false, nothing recorded');

select is(array[pg_temp.run_as('owner', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000b1', 'down', gen_random_uuid(), 'x')$$),
                pg_temp.run_as('owner', $$select public.set_machine_status(gen_random_uuid(), 'down', gen_random_uuid(), 'x')$$),
                pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000c1', 'down', gen_random_uuid(), 'x')$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}', 'no oracle: another tenant''s, a missing, and another plant''s machine look the same');
select is(array[
  pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a4', 'down', gen_random_uuid())$$),
  pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a4', 'down', gen_random_uuid(), '   ')$$),
  pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a4', 'down', gen_random_uuid(), repeat('x', 201))$$),
  pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a4', 'down', gen_random_uuid(), E'a\nb')$$),
  pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a4', null, gen_random_uuid(), 'x')$$),
  pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a4', 'down', null, 'x')$$),
  pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a5', 'down', gen_random_uuid(), 'x')$$)],
  array['VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED'],
  'rejects: down without a reason, blank reason, reason > 200, control characters, no status, no client_id, an inactive machine');
select is(pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a6', 'down', pg_temp.cid(1), repeat('y', 200))$$),
  '1', 'any machine kind (an ironer in finishing) can be marked down; 200 characters is the limit');
select is(pg_temp.val_as('owner', $$select row((r).event_id = (select id from public.machine_status_events where client_id = pg_temp.cid(1)), (r).changed)::text
                                      from (select public.set_machine_status('60000000-0000-0000-0000-0000000000a6', 'up', pg_temp.cid(1)) as r) x$$),
  '(t,f)', 'idempotent: a retry with the same client_id returns the recorded event (changed = false)');
select is(pg_temp.run_as('ownerB', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000b1', 'down', pg_temp.cid(1), 'x')$$),
  'VALIDATION_FAILED', 'a client_id used in another tenant is rejected (never returns their event)');
select is(pg_temp.val_as('manager', $$select row((r).status, (r).reason, (r).changed)::text
                                        from (select public.set_machine_status('60000000-0000-0000-0000-0000000000a6', 'up', gen_random_uuid(), 'Belt replaced') as r) x$$),
  '(up,"Belt replaced",t)', 'back up, with an optional note');
select is((select count(*)::int from public.alert_events where kind = 'machine_down' and plant_id = pg_temp.id('plantA')), 2, 'up writes no alert; each down event writes one');
select is(pg_temp.val_as('owner', $$select (public.set_machine_status('60000000-0000-0000-0000-0000000000a4', 'up', gen_random_uuid())).event_id$$),
  null, 'marking a machine up that was never down records nothing');

-- ══ machine_status_events table: RLS, append-only, CHECKs ════════════════
select is(pg_temp.reads($$select 1 from public.machine_status_events$$), '{3,3,3,3,0,0,0,42501}',
  'reads: owner/manager/lead/viewer of the plant; display, other tenant: no rows; anon: no privilege');
select is(array[
  pg_temp.run_as('owner', $$insert into public.machine_status_events (org_id, plant_id, machine_id, status, reason, client_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('machine'), 'up', null, gen_random_uuid())$$),
  pg_temp.run_as('owner', $$update public.machine_status_events set reason = 'x'$$),
  pg_temp.run_as('owner', $$delete from public.machine_status_events$$)],
  '{42501,42501,42501}', 'no direct client writes (RPC only)');
select is(array[
  pg_temp.as_service($$update public.machine_status_events set reason = 'x'$$),
  pg_temp.as_service($$delete from public.machine_status_events$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED}', 'append-only even for the service role');
select is(array[
  pg_temp.as_service($$insert into public.machine_status_events (org_id, plant_id, machine_id, status, client_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('machine'), 'down', gen_random_uuid())$$),
  pg_temp.as_service($$insert into public.machine_status_events (org_id, plant_id, machine_id, status, reason, client_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('machine'), 'down', repeat('z', 201), gen_random_uuid())$$),
  pg_temp.as_service($$insert into public.machine_status_events (org_id, plant_id, machine_id, status, client_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), '60000000-0000-0000-0000-0000000000b1', 'up', gen_random_uuid())$$)],
  '{23514,23514,23503}', 'CHECKs: down needs a reason, reason ≤ 200; composite FK: no machine of another plant');

-- ══ get_machine_status ═══════════════════════════════════════════════════
select is(pg_temp.reads($$select * from public.get_machine_status(pg_temp.id('plantA'))$$),
  '{4,4,4,4,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'get_machine_status: every active machine of the plant (not inactive Washer 5); plant roles only');
select is(array[pg_temp.run_as('ownerB', $$select * from public.get_machine_status(pg_temp.id('plantA'))$$),
                pg_temp.run_as('ownerB', $$select * from public.get_machine_status(gen_random_uuid())$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED}', 'no oracle (foreign vs missing plant)');
select is(pg_temp.val_as('manager', $$select array_agg(machine_name || ':' || kind || ':' || status || ':' || coalesce(reason, '-') || ':' || (since is not null)::text order by machine_name)::text
                                    from public.get_machine_status(pg_temp.id('plantA'))$$),
  '{"Dryer 1:dryer:up:-:false","Ironer M:ironer:up:Belt replaced:true","Washer 1:washer:down:Door latch broken:true","Washer 3:washer:up:-:false"}',
  'status per machine: down with reason and since; up after a fix keeps its note; never-down machines: up, since null');

-- ══ start_washer_load: MACHINE_DOWN and p_tapped_at ══════════════════════
select is(pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), null, pg_temp.id('gMat'))$$),
  'MACHINE_DOWN', 'a down washer refuses a start-tap');
select is(pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(10), null, pg_temp.id('gMat'), now() - interval '5 minutes')$$),
  '1', 'an offline tap made BEFORE the washer was marked down is still recorded');
select is((select started_at from public.washer_cycles where id = pg_temp.cyc(10)), now() - interval '5 minutes',
  'started_at = the device tap time');
select is(array[
  pg_temp.run_as('lead', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000a3', gen_random_uuid(), null, pg_temp.id('gMat'), now() - interval '31 minutes')$$),
  pg_temp.run_as('lead', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000a3', gen_random_uuid(), null, pg_temp.id('gMat'), now() + interval '2 minutes')$$)],
  '{OUT_OF_RANGE_TIMESTAMP,OUT_OF_RANGE_TIMESTAMP}', 'p_tapped_at outside [now − 30 min, now + 1 min] is rejected');
select is(pg_temp.run_as('lead', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000a3', pg_temp.cid(11), null, pg_temp.id('gMat'), now() + interval '30 seconds')$$),
  '1', 'up to 1 minute ahead is accepted (device clock skew)');
select is(pg_temp.val_as('lead', $$select (public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(10), null, pg_temp.id('gMat'), now() - interval '2 hours')).duplicate$$),
  'true', 'idempotency is checked before the window and the down check: a late retry returns the recorded tap');
select is(pg_temp.run_as('ownerB', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), null, null, now() - interval '2 hours')$$),
  'NOT_AUTHORIZED', 'role check first: another tenant learns nothing about the washer (window, down)');

-- Shift and production day follow the tap time (plant A2: a shift that ended 10 minutes ago).
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week, active) values
  ('90000000-0000-0000-0000-0000000000c1', pg_temp.id('orgA'), pg_temp.id('plantA2'), pg_temp.id('washA2'), 'Test', '00:00', '01:00', '{0}', false);
insert into public.shift_instances (id, org_id, plant_id, area_id, shift_id, business_date, starts_at, ends_at) values
  ('91000000-0000-0000-0000-0000000000c1', pg_temp.id('orgA'), pg_temp.id('plantA2'), pg_temp.id('washA2'),
   '90000000-0000-0000-0000-0000000000c1', '2000-01-01', now() - interval '2 hours', now() - interval '10 minutes');
update public.shift_instances set production_date = '2000-01-01' where id = '91000000-0000-0000-0000-0000000000c1';
select is(pg_temp.run_as('owner', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000c1', pg_temp.cid(12), null, pg_temp.id('groupA2'), now() - interval '20 minutes')$$),
  '1', 'offline tap 20 minutes ago (inside the shift that has since ended)');
select is(pg_temp.run_as('owner', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000c1', pg_temp.cid(13), null, pg_temp.id('groupA2'))$$),
  '1', 'a tap now (after the shift ended: off-shift)');
select is((select array[shift_instance_id::text, production_date::text] from public.washer_cycles where id = pg_temp.cyc(12)),
  array['91000000-0000-0000-0000-0000000000c1', '2000-01-01'], 'the offline tap lands in the shift and production day of its tap time');
select is((select array[coalesce(shift_instance_id::text, 'null'), (production_date = app.production_date(now(), 'America/New_York', '12:00'))::text]
             from public.washer_cycles where id = pg_temp.cyc(13)),
  array['null', 'true'], 'the tap now is off-shift, in the current production day');

-- Undo of a backdated tap: the window and the queue reopen follow when it was RECORDED.
select is(pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', pg_temp.cid(20), pg_temp.id('gNapkin'), p_assigned_machine_id => '60000000-0000-0000-0000-0000000000a3')$$),
  '1', 'a one-load item assigned to Washer 3');
select is(pg_temp.val_as('lead', $$select (public.start_washer_load('60000000-0000-0000-0000-0000000000a3', pg_temp.cid(21), p_tapped_at => now() - interval '29 minutes')).queue_status$$),
  'done', 'an offline tap 29 minutes ago completes it');
select is(pg_temp.val_as('lead', $$select (public.undo_washer_load(pg_temp.cyc(21))).queue_status$$),
  'queued', 'undo still works (recorded just now) and puts the item back in the queue');

-- ══ get_washroom_board: down washers ═════════════════════════════════════
select is(pg_temp.val_as('display', $$select array_agg(machine_name || ':' || is_down || ':' || coalesce(down_reason, '-') || ':' || (down_since is not null) || ':' || coalesce(next_queue_item_id::text, '-') order by machine_name)::text
                                       from public.get_washroom_board(pg_temp.id('wash'))$$),
  (select array['Washer 1:true:-:true:-',
                'Washer 3:false:-:false:' || (select id from public.queue_items where client_id = pg_temp.cid(20))]::text),
  'board (the washroom TV too): a down washer shows since-when and no NEXT (the reason is for owner/manager only, see 152); an up washer is unchanged');

-- ══ queue assignment never targets a down washer ═════════════════════════
select is(pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'), p_assigned_machine_id => pg_temp.id('machine'))$$),
  'MACHINE_DOWN', 'create: cannot assign to a down washer');
select is(pg_temp.run_as('owner', $$select public.update_queue_item(q.id, q.version, q.qty, q.unit, q.is_rush, q.is_rewash, q.note, pg_temp.id('machine'))
                                      from public.queue_items q where q.client_id = pg_temp.cid(20)$$),
  'MACHINE_DOWN', 'update: cannot move work onto a down washer');

-- Back up: taps and assignment work again.
select is(pg_temp.val_as('manager', $$select (public.set_machine_status(pg_temp.id('machine'), 'up', gen_random_uuid())).changed$$), 'true', 'Washer 1 back up');
select is(pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), null, pg_temp.id('gMat'))$$),
  '1', 'start-taps work again once the washer is up');
select is(pg_temp.val_as('owner', $$select (is_down, down_reason, down_since)::text from public.get_washroom_board(pg_temp.id('wash')) where machine_name = 'Washer 1'$$),
  '(f,,)', 'board: up again, no reason or since');
select is(pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), null, pg_temp.id('gMat'), now() - interval '1 minute')$$),
  '1', 'a tap stamped before the down event is accepted (the washer was up then)');

-- Every event and alert is per plant; nothing leaks to plant B.
select is(pg_temp.run_as('ownerB', $$select 1 from public.machine_status_events$$, true), '0', 'owner B sees no plant A events');
select is((select count(*)::int from public.machine_status_events where plant_id = pg_temp.id('plantA')), 4, 'four events: down + up for Washer 1, down + up for the ironer');
select is((select count(*)::int from public.alert_events a join public.machine_status_events e on e.id = a.subject_id
            where a.kind = 'machine_down' and e.status = 'down' and e.plant_id = a.plant_id and a.plant_id = pg_temp.id('plantA')), 2, 'each down event has exactly one alert, in its plant');
select is((select count(*)::int from pg_proc p where p.proname = 'get_machine_status'
             and pg_get_function_result(p.oid) like '%entered_by%'), 0, 'no per-person column in the read RPC');

select * from finish();
rollback;
