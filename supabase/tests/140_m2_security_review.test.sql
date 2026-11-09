-- M2 security review (2026-11-04, PASS WITH NOTES) follow-up tests: staff sessions across a manager's
-- two plants, no-oracle pairs on reorder/update references, the password gate on every M2 RPC,
-- display access from revoked or device-less display accounts, the L2 reopen rule, cron schema ACLs.
begin;
\ir _fixtures.psql
select plan(13);

-- ── Data (service role) ───────────────────────────────────────────────────
-- The plant A manager also manages plant A2; staff Ana (A) and Ava (A2).
insert into public.memberships (user_id, org_id, plant_id, role) values
  (pg_temp.id('manager'), pg_temp.id('orgA'), pg_temp.id('plantA2'), 'manager');
insert into public.entry_staff (id, org_id, plant_id, display_name, pin_hash) values
  ('b0000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'),  'Ana', extensions.crypt('2580', extensions.gen_salt('bf'))),
  ('b0000000-0000-0000-0000-0000000000c1', pg_temp.id('orgA'), pg_temp.id('plantA2'), 'Ava', extensions.crypt('2580', extensions.gen_salt('bf')));
insert into public.machines (id, org_id, plant_id, area_id, name, kind) values
  ('60000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), 'Washer B', 'washer'),
  ('60000000-0000-0000-0000-0000000000c1', pg_temp.id('orgA'), pg_temp.id('plantA2'), pg_temp.id('washA2'), 'Washer A2', 'washer');
insert into public.queue_items (id, org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id) values
  ('e0000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), 2, 'load', 1, pg_temp.id('owner'), gen_random_uuid()),
  ('e0000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gMat'),    1, 'load', 2, pg_temp.id('owner'), gen_random_uuid()),
  ('e0000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), pg_temp.id('groupB'), 1, 'load', 1, pg_temp.id('ownerB'), gen_random_uuid());
insert into public.washer_cycles (id, org_id, plant_id, area_id, wash_group_id, machine_id, started_at, source, entered_by, client_id) values
  ('f1000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), pg_temp.id('machine'), now(), 'manual', pg_temp.id('lead'), gen_random_uuid());
insert into public.finished_goods_entries (id, org_id, plant_id, area_id, item_type_id, loose_pieces, entered_by, client_id) values
  ('f0000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 5, pg_temp.id('manager'), gen_random_uuid());

-- ── Staff sessions are bound to the plant ─────────────────────────────────
select set_config('test.a2s', pg_temp.val_as('manager', $$select (public.start_staff_session('b0000000-0000-0000-0000-0000000000c1', '2580')).staff_session_id::text$$), true);
select ok(current_setting('test.a2s') ~ '^[0-9a-f-]{36}$', 'the manager confirms Ava (plant A2)');
select is(array[pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 1, gen_random_uuid(), current_setting('test.a2s')::uuid)$$),
                pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gMat'), 1, 'load', gen_random_uuid(), current_setting('test.a2s')::uuid)$$)],
  '{1,1}', 'since 2026-11-07 the session id is ignored: a plant A2 session never attributes a plant A entry (staff_id stays null)');

-- ── No-oracle pairs on references ─────────────────────────────────────────
select is(array[pg_temp.run_as('owner', $$select public.reorder_queue_item('e0000000-0000-0000-0000-0000000000a2', 1, 'e0000000-0000-0000-0000-0000000000b1')$$),
                pg_temp.run_as('owner', $$select public.reorder_queue_item('e0000000-0000-0000-0000-0000000000a2', 1, gen_random_uuid())$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED}', 'reorder: a foreign p_after_id and a missing one give the same code');
select is(array[pg_temp.run_as('owner', $$select public.update_queue_item('e0000000-0000-0000-0000-0000000000a1', 1, 2, 'load', false, false, null, '60000000-0000-0000-0000-0000000000b1')$$),
                pg_temp.run_as('owner', $$select public.update_queue_item('e0000000-0000-0000-0000-0000000000a1', 1, 2, 'load', false, false, null, '60000000-0000-0000-0000-0000000000c1')$$),
                pg_temp.run_as('owner', $$select public.update_queue_item('e0000000-0000-0000-0000-0000000000a1', 1, 2, 'load', false, false, null, gen_random_uuid())$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}', 'update: another tenant''s washer, another plant''s washer and a missing id give the same code');

-- ── Password gate on every M2 RPC ─────────────────────────────────────────
create function pg_temp.run_flag(p_user text, p_flag boolean, p_sql text) returns text language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.id(p_user), 'role', 'authenticated',
                     'app_metadata', json_build_object('must_change_password', p_flag))::text, true);
  perform set_config('role', 'authenticated', true);
  execute p_sql;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  return 'ok';
exception when others then
  perform set_config('request.jwt.claims', '', true);
  return case when sqlstate = 'P0001' then sqlerrm else sqlstate end;
end;
$$;
create temp table rpc_calls (name text, sql text);
insert into rpc_calls values
  ('create_queue_item',     $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'))$$),
  ('reorder_queue_item',    $$select public.reorder_queue_item('e0000000-0000-0000-0000-0000000000a2', 99, null)$$),
  ('update_queue_item',     $$select public.update_queue_item('e0000000-0000-0000-0000-0000000000a2', 99, 1, 'load', false, false)$$),
  ('cancel_queue_item',     $$select public.cancel_queue_item('e0000000-0000-0000-0000-0000000000a2', 99)$$),
  ('set_queue_item_status', $$select public.set_queue_item_status('e0000000-0000-0000-0000-0000000000a2', 'done', 99)$$),
  ('get_queue',             $$select * from public.get_queue(pg_temp.id('wash'))$$),
  ('start_washer_load',     $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), null, pg_temp.id('gMat'), p_off_queue_reason => 'other')$$),
  ('undo_washer_load',      $$select public.undo_washer_load('f1000000-0000-0000-0000-0000000000a1')$$),
  ('get_washroom_board',    $$select * from public.get_washroom_board(pg_temp.id('wash'))$$),
  ('record_soil_estimate',  $$select public.record_soil_estimate(pg_temp.id('gMat'), 1, 'load', gen_random_uuid(), null)$$),
  ('record_finished_goods', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 1, gen_random_uuid(), null)$$),
  ('void_finished_goods',   $$select public.void_finished_goods('f0000000-0000-0000-0000-0000000000a1', 'x')$$),
  ('get_shift_report',      $$select public.get_shift_report(pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03'))$$),
  ('get_day_report',        $$select public.get_day_report(pg_temp.id('plantA'), '2026-11-02')$$),
  ('get_wash_group_pace',   $$select * from public.get_wash_group_pace(pg_temp.id('plantA'))$$);
grant select on rpc_calls to authenticated;
select is((select count(*)::int from rpc_calls), 15, 'the 15 M2 RPCs');
select is((select array_agg(c.name order by c.name) from rpc_calls c where pg_temp.run_flag('owner', true, c.sql) <> 'NOT_AUTHORIZED'),
  null, 'password gate: every M2 RPC answers NOT_AUTHORIZED while must_change_password is set');
select is((select array_agg(c.name order by c.name) from rpc_calls c where pg_temp.run_flag('owner', false, c.sql) = 'NOT_AUTHORIZED'),
  null, 'with the flag cleared none of them is NOT_AUTHORIZED (the gate is the cause)');

-- ── Display reads: revoked device, and a display account without a device (no area) ──
select is(array[pg_temp.run_as('display_nodev', $$select * from public.get_queue(pg_temp.id('wash'))$$, true),
                pg_temp.run_as('display_nodev', $$select * from public.get_washroom_board(pg_temp.id('wash'))$$, true)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED}', 'a display account with no device (so no area) is denied (devices.area_id is NOT NULL)');
select is(array[pg_temp.run_as('display', $$select * from public.get_queue(pg_temp.id('wash'))$$, true),
                pg_temp.run_as('display', $$select * from public.get_washroom_board(pg_temp.id('wash'))$$, true)],
  '{3,1}', 'the paired washroom display reads its area (3 items: + the Mats estimate item, owner 2026-11-09)');
update public.devices set revoked_at = now() where id = pg_temp.id('device');
select is(array[pg_temp.run_as('display', $$select * from public.get_queue(pg_temp.id('wash'))$$, true),
                pg_temp.run_as('display', $$select * from public.get_washroom_board(pg_temp.id('wash'))$$, true)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED}', 'a revoked device is denied');

-- ── L2: reopen moves are tied to a lower loads_started, not to a session setting ──
insert into public.queue_items (id, org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id) values
  ('e0000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('gTowel'), 1, 'load', 1, pg_temp.id('owner'), gen_random_uuid());
update public.queue_items set status = 'in_progress' where id = 'e0000000-0000-0000-0000-0000000000a3';
update public.queue_items set status = 'done' where id = 'e0000000-0000-0000-0000-0000000000a3';
select set_config('app.queue_undo', 'on', true);
-- The version is read here, not as the manager: RLS shows a manager a done item only inside the current shift.
select set_config('test.a3_version', (select version::text from public.queue_items where id = 'e0000000-0000-0000-0000-0000000000a3'), true);
select is(pg_temp.run_as('manager', $$select public.set_queue_item_status('e0000000-0000-0000-0000-0000000000a3', 'in_progress',
            current_setting('test.a3_version')::int)$$),
  'INVALID_STATUS_TRANSITION', 'L2: setting app.queue_undo no longer reopens a done item');
select is(pg_temp.as_service($$update public.queue_items set status = 'queued' where id = 'e0000000-0000-0000-0000-0000000000a3'$$),
  'INVALID_STATUS_TRANSITION', 'L2: done → queued without giving a load back is rejected');

-- ── pg_cron schema ACL ────────────────────────────────────────────────────
select is(array[has_schema_privilege('anon', 'cron', 'usage'), has_schema_privilege('authenticated', 'cron', 'usage')],
  array[false, false], 'clients have no USAGE on the cron schema');

select * from finish();
rollback;
