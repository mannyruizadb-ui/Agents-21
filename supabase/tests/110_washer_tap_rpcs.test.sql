-- M2 washroom start-taps (PRD F1, D1 v1.6; owner decisions 2026-11-02/03): start_washer_load,
-- undo_washer_load, get_washroom_board. No name/PIN on taps. Picks assigned before unassigned, copies
-- rewash, advances the queue, is idempotent, and undo works only within 30 minutes.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(41);

-- Napkins wash on the fixture formula (30 min); Mats have no formula (cycle time unknown).
update public.wash_formulas set cycle_minutes = 30 where id = pg_temp.id('formula');
update public.wash_groups set wash_formula_id = pg_temp.id('formula') where id = pg_temp.id('gNapkin');
insert into public.machines (id, org_id, plant_id, area_id, name, kind, active, load_factor) values
  ('60000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 2', 'washer', true, 1.19),
  ('60000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 3', 'washer', true, 1.00),
  ('60000000-0000-0000-0000-0000000000a5', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 5', 'washer', false, 1.00),
  ('60000000-0000-0000-0000-0000000000a4', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Dryer 1', 'dryer', true, 1.00),
  ('60000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), 'Washer B', 'washer', true, 1.00);

create function pg_temp.cid(n int) returns uuid language sql immutable as $$
  select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;
$$;
create function pg_temp.q(n int) returns uuid language sql stable as $$
  select id from public.queue_items where client_id = pg_temp.cid(n);
$$;
create function pg_temp.cyc(n int) returns uuid language sql stable as $$
  select id from public.washer_cycles where client_id = pg_temp.cid(n);
$$;
grant execute on function pg_temp.cid(int), pg_temp.q(int), pg_temp.cyc(int) to authenticated, anon;
create function pg_temp.qstate(n int) returns text[] language sql stable as $$
  select array[status::text, loads_started::text] from public.queue_items where id = pg_temp.q(n);
$$;

-- ── Role matrix (empty queue: off-queue loads of a chosen group) ──────────
select is(pg_temp.writes($$select public.start_washer_load('60000000-0000-0000-0000-0000000000a3', gen_random_uuid(), null, pg_temp.id('gMat'))$$),
  '{1,1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'start_washer_load: owner/manager/lead, no staff session (viewer, display, other tenant: NOT_AUTHORIZED; anon: no EXECUTE)');
select is((select array[count(*)::text, bool_and(queue_item_id is null and staff_id is null and source = 'manual' and load_count = 1)::text]
             from public.washer_cycles where machine_id = '60000000-0000-0000-0000-0000000000a3'),
  array['3', 'true'], 'three off-queue loads: no queue item, no staff (station tap), manual, one load each');
select is(pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid())$$), 'VALIDATION_FAILED',
  'nothing queued and no group chosen → VALIDATION_FAILED');

-- ── Queue: A napkins ×2 assigned to Washer 1; U mats ×1 RUSH unassigned; R towels rewash ×1 unassigned;
--    W2 mats ×1 assigned to Washer 2; F a finishing item.
select is(array[
  pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 2, 'load', pg_temp.cid(1), pg_temp.id('gNapkin'), p_assigned_machine_id => pg_temp.id('machine'))$$),
  pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', pg_temp.cid(2), pg_temp.id('gMat'), p_is_rush => true)$$),
  pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', pg_temp.cid(3), pg_temp.id('gTowel'), p_is_rewash => true)$$),
  pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', pg_temp.cid(4), pg_temp.id('gMat'), p_assigned_machine_id => '60000000-0000-0000-0000-0000000000a2')$$),
  pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('fin'), 10, 'piece', pg_temp.cid(5), p_item_type_id => pg_temp.id('mat'))$$)],
  '{1,1,1,1,1}', 'queue set up');

-- ── Picking and advancing ─────────────────────────────────────────────────
select is(pg_temp.val_as('lead', $$select (public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(101))).queue_item_id$$),
  pg_temp.q(1)::text, 'Washer 1: the item ASSIGNED to it wins over an unassigned RUSH item');
select is(pg_temp.qstate(1), array['in_progress', '1'], 'first load: queued → in_progress, loads_started 1');
select is((select array[wash_group_id::text, wash_formula_id::text, load_factor_used::text, entered_by::text, coalesce(staff_id::text, 'null'), is_rewash::text]
             from public.washer_cycles where id = pg_temp.cyc(101)),
  array[pg_temp.id('gNapkin')::text, pg_temp.id('formula')::text, '1.00', pg_temp.id('lead')::text, 'null', 'false'],
  'cycle: group, the group''s formula, machine load factor, entered_by = the station account, no staff');
select ok((select shift_instance_id is not distinct from app.shift_instance_at(pg_temp.id('wash'), started_at)
             and production_date = coalesce((select si.production_date from public.shift_instances si where si.id = w.shift_instance_id),
                                            app.production_date(started_at, 'America/New_York', '12:00'))
             from public.washer_cycles w where id = pg_temp.cyc(101)),
  'shift = the area''s clock instance (or off-shift); production_date stored');
select is(pg_temp.val_as('lead', $$select (public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(102))).queue_status$$),
  'done', 'second load completes the 2-load item');
select is(pg_temp.qstate(1), array['done', '2'], 'item A done after 2 loads');
select is(pg_temp.val_as('manager', $$select (public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(103))).queue_item_id$$),
  pg_temp.q(2)::text, 'Washer 1, nothing assigned left: the top UNASSIGNED item (the rush one)');
select is(pg_temp.val_as('owner', $$select (public.start_washer_load('60000000-0000-0000-0000-0000000000a2', pg_temp.cid(104))).queue_item_id$$),
  pg_temp.q(4)::text, 'Washer 2 takes the item assigned to it');
select is(pg_temp.val_as('owner', $$select (public.start_washer_load('60000000-0000-0000-0000-0000000000a2', pg_temp.cid(105))).is_rewash$$),
  'true', 'Washer 2 then takes the unassigned rewash item: is_rewash copied to the cycle');
select is((select array[load_factor_used::text, queue_item_id::text] from public.washer_cycles where id = pg_temp.cyc(105)),
  array['1.19', pg_temp.q(3)::text], 'the 1.19 washer''s factor is snapshotted');

-- Idempotency: the same client_id gives one row and nothing advances twice.
select is(pg_temp.val_as('owner', $$select (public.start_washer_load('60000000-0000-0000-0000-0000000000a2', pg_temp.cid(105))).duplicate$$),
  'true', 'retry with the same client_id → duplicate');
select is(array[(select count(*)::text from public.washer_cycles where client_id = pg_temp.cid(105)), (pg_temp.qstate(3))[2]],
  array['1', '1'], 'one row; loads_started not advanced twice');
select is(pg_temp.run_as('ownerB', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000b1', pg_temp.cid(105), null, pg_temp.id('groupB'))$$),
  'VALIDATION_FAILED', 'another tenant''s client_id is rejected, never returned');

-- Explicit choices and validation.
select is(pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 3, 'load', pg_temp.cid(6), pg_temp.id('gNapkin'))$$), '1', 'more napkins');
select is(pg_temp.val_as('lead', $$select (public.start_washer_load('60000000-0000-0000-0000-0000000000a3', pg_temp.cid(106), null, pg_temp.id('gNapkin'))).queue_item_id$$),
  pg_temp.q(6)::text, 'with a chosen group, the top open item of that group');
select is(pg_temp.val_as('lead', $$select (public.start_washer_load('60000000-0000-0000-0000-0000000000a3', pg_temp.cid(107), pg_temp.q(6))).queue_item_id$$),
  pg_temp.q(6)::text, 'an explicit open item of the washer''s area');
select is(array[
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), pg_temp.q(5))$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), pg_temp.q(6), pg_temp.id('gMat'))$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), pg_temp.q(1))$$),
  pg_temp.run_as('lead', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000a5', gen_random_uuid(), null, pg_temp.id('gMat'))$$),
  pg_temp.run_as('lead', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000a4', gen_random_uuid(), null, pg_temp.id('gMat'))$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), null, null, pg_temp.id('gMat'))$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}',
  'rejects: a finishing item, a group that does not match the item, a done item, an inactive washer, a dryer, no client_id');

-- No oracle.
select is(array[pg_temp.run_as('owner', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000b1', gen_random_uuid(), null, pg_temp.id('groupB'))$$),
                pg_temp.run_as('owner', $$select public.start_washer_load(gen_random_uuid(), gen_random_uuid(), null, pg_temp.id('groupB'))$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED}', 'no oracle: another tenant''s washer vs a missing machine');
select is(array[pg_temp.run_as('ownerB', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000b1', gen_random_uuid(), pg_temp.q(6))$$),
                pg_temp.run_as('ownerB', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000b1', gen_random_uuid(), pg_temp.q(3))$$),
                pg_temp.run_as('ownerB', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000b1', gen_random_uuid(), gen_random_uuid())$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}', 'no oracle: plant A queue items (normal or rewash) vs a missing id, on owner B''s washer');
select is(array[pg_temp.run_as('ownerB', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000b1', gen_random_uuid(), null, pg_temp.id('gNapkin'))$$),
                pg_temp.run_as('ownerB', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000b1', gen_random_uuid(), null, gen_random_uuid())$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED}', 'no oracle: a plant A group vs a missing group');
select is((select count(*)::int from public.queue_items where plant_id = pg_temp.id('plantA') and loads_started > 0 and status = 'queued'), 0,
  'no plant A queue item was touched by the failed calls');

-- ── undo_washer_load ──────────────────────────────────────────────────────
select is(array[pg_temp.run_as('viewer', $$select public.undo_washer_load(pg_temp.cyc(102))$$),
                pg_temp.run_as('display', $$select public.undo_washer_load(pg_temp.cyc(102))$$),
                pg_temp.run_as('ownerB', $$select public.undo_washer_load(pg_temp.cyc(102))$$),
                pg_temp.run_as('ownerB', $$select public.undo_washer_load(gen_random_uuid())$$),
                pg_temp.run_as('anon', $$select public.undo_washer_load(pg_temp.cyc(102))$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'undo: viewer, display, other tenant (foreign or missing id) denied');
select is(pg_temp.val_as('lead', $$select (public.undo_washer_load(pg_temp.cyc(102), 'wrong washer')).queue_status$$),
  'in_progress', 'undo of the tap that completed item A reopens it (done → in_progress)');
select is(pg_temp.qstate(1), array['in_progress', '1'], 'item A: one load left again');
select is((select array[(voided_at is not null)::text, voided_by::text, void_reason] from public.washer_cycles where id = pg_temp.cyc(102)),
  array['true', pg_temp.id('lead')::text, 'wrong washer'], 'the cycle is voided (never deleted) with who and why');
select is(pg_temp.val_as('lead', $$select (public.undo_washer_load(pg_temp.cyc(102))).duplicate$$), 'true', 'undo again: idempotent');
select is(pg_temp.val_as('manager', $$select (public.undo_washer_load(pg_temp.cyc(105))).queue_status$$),
  'queued', 'undo of the only load of the rewash item puts it back in the queue');
select is((select array[status::text, loads_started::text, coalesce(started_at::text, 'null')] from public.queue_items where id = pg_temp.q(3)),
  array['queued', '0', 'null'], 'rewash item: queued, 0 loads, started_at cleared');
update public.washer_cycles set started_at = now() - interval '31 minutes', created_at = now() - interval '31 minutes' where id = pg_temp.cyc(103);
select is(pg_temp.run_as('lead', $$select public.undo_washer_load(pg_temp.cyc(103))$$), 'OUT_OF_RANGE_TIMESTAMP', 'no undo 30 minutes after the tap was recorded (created_at)');
select is((select coalesce(sum(loads_run), 0)::int from public.washroom_by_shift where plant_id = pg_temp.id('plantA')),
  (select count(*)::int from public.washer_cycles where plant_id = pg_temp.id('plantA') and voided_at is null),
  'voided loads leave every report');
select is(pg_temp.as_service($$update public.queue_items set status = 'queued' where id = (select id from public.queue_items where status = 'in_progress' limit 1)$$),
  'INVALID_STATUS_TRANSITION', 'the reopen moves stay closed outside undo_washer_load');

-- ── get_washroom_board ────────────────────────────────────────────────────
-- Distinct start times (one test transaction has one now()).
update public.washer_cycles set started_at = now() - interval '40 minutes' where id = pg_temp.cyc(101);   -- Washer 1: napkins, 30-min formula
update public.washer_cycles set started_at = now() - interval '50 minutes' where id = pg_temp.cyc(103);
update public.washer_cycles set started_at = now() - interval '45 minutes' where machine_id = '60000000-0000-0000-0000-0000000000a3' and client_id not in (pg_temp.cid(106), pg_temp.cid(107));
update public.washer_cycles set started_at = now() - interval '5 minutes' where id = pg_temp.cyc(106);
update public.washer_cycles set started_at = now() - interval '1 minute' where id = pg_temp.cyc(107);
select is(pg_temp.reads($$select * from public.get_washroom_board(pg_temp.id('wash'))$$),
  '{3,3,3,3,3,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'board: one row per ACTIVE washer; plant roles and the washroom display only');
select is(pg_temp.run_as('display', $$select * from public.get_washroom_board(pg_temp.id('fin'))$$, true), 'NOT_AUTHORIZED',
  'a display cannot read another area''s board');
select is(pg_temp.val_as('viewer', $$select array_agg(machine_name || ':' || status || ':' || coalesce(minutes_ready::text, '-') order by machine_name)::text
                                     from public.get_washroom_board(pg_temp.id('wash'))$$),
  '{"Washer 1:ready:10","Washer 2:unknown:-","Washer 3:running:-"}',
  'status: Washer 1 ready 10 min (40 min into a 30-min formula); Washer 2 ran towels (no cycle time); Washer 3 running napkins');
select is(pg_temp.val_as('owner', $$select array_agg(machine_name || ':' || next_queue_item_id::text || ':' || next_is_assigned::text order by machine_name)::text
                                     from public.get_washroom_board(pg_temp.id('wash'))$$),
  (select array[('Washer 1:' || pg_temp.q(1) || ':true'), ('Washer 2:' || pg_temp.q(6) || ':false'), ('Washer 3:' || pg_temp.q(6) || ':false')]::text),
  'NEXT: the item assigned to the washer, else the top unassigned item (a reopened item keeps its old position)');
select is(pg_temp.val_as('owner', $$select (expected_end_at - started_at)::text from public.get_washroom_board(pg_temp.id('wash')) where machine_name = 'Washer 3'$$),
  '00:30:00', 'expected_end_at = started_at + the formula''s cycle_minutes');
select ok(pg_temp.val_as('owner', $$select bool_and(server_time is not null) from public.get_washroom_board(pg_temp.id('wash'))$$)::boolean,
  'server_time for the data-age display');

select * from finish();
rollback;
