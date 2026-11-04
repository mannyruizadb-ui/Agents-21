-- E1/E4/A5/F1/F3: finished_goods_entries, shift_crew_hours, import_batches, washer_cycles.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(61);

-- Fixture rows (as the service role): Napkin 7 packs + 34 loose and Mat 25 at Tue 11:30 (finishing Day).
insert into public.finished_goods_entries (id, org_id, plant_id, area_id, item_type_id, packs, loose_pieces, occurred_at, entered_by, client_id) values
  ('f0000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 7, 34,
   pg_temp.ny('2026-11-03 11:30'), pg_temp.id('owner'), gen_random_uuid()),
  ('f0000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 0, 25,
   pg_temp.ny('2026-11-03 11:30'), pg_temp.id('owner'), gen_random_uuid());
insert into public.washer_cycles (id, org_id, plant_id, area_id, wash_group_id, started_at, load_count, source, entered_by, client_id) values
  ('f1000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'),
   pg_temp.ny('2026-11-03 01:00'), 3, 'manual', pg_temp.id('owner'), gen_random_uuid());
insert into public.shift_crew_hours (org_id, plant_id, shift_instance_id, area_id, crew_count, labor_hours, entered_by) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03'), pg_temp.id('fin'), 4, 24, pg_temp.id('owner'));
insert into public.import_batches (org_id, plant_id, source, created_by) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'accuflow_csv', pg_temp.id('owner'));

-- ── finished_goods_entries: owner/manager R C; lead, viewer R; display none; no direct U (D8) ──
select is(pg_temp.reads($$select 1 from public.finished_goods_entries where plant_id = pg_temp.id('plantA')$$), '{2,2,2,2,0,0,0,0}', 'finished goods R (display: none)');
select is(pg_temp.writes($$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 5, (select auth.uid()), gen_random_uuid())$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'M2: no direct finished goods insert for any role (record_finished_goods only)');
select is(pg_temp.run_as('manager', $$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 5, pg_temp.id('owner'), gen_random_uuid())$$),
  '42501', 'entered_by is pinned to the caller');
select is(pg_temp.writes($$update public.finished_goods_entries set note = 'x'$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'D8: no direct UPDATE on finished goods for any role');
select is(pg_temp.run_as('owner', $$update public.finished_goods_entries set voided_at = now(), void_reason = 'typo' where id = 'f0000000-0000-0000-0000-0000000000a1'$$),
  '42501', 'D8: voids are not direct updates (RPC in M2)');
select throws_ok($$delete from public.finished_goods_entries$$, 'P0001', 'VALIDATION_FAILED', 'prevent_delete on finished goods');
select throws_ok($$truncate public.finished_goods_entries, public.washer_cycles$$, 'P0001', 'VALIDATION_FAILED', 'L2: TRUNCATE blocked by trigger');
select is(pg_temp.run_as('owner', $$truncate public.finished_goods_entries$$), '42501', 'L2: clients have no TRUNCATE privilege');
select is(pg_temp.run_as('manager', $$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, entered_by, client_id, voided_at, void_reason)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 5, (select auth.uid()), gen_random_uuid(), now(), 'pre-voided')$$),
  '42501', 'L4: rows cannot be inserted already voided');
select is(pg_temp.run_as('ownerB', $$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, packs, pack_size_used, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 1, 10, (select auth.uid()), gen_random_uuid())$$),
  '42501', 'security M2: apply_count_mode is not a cross-tenant oracle');
-- Attack (a): plant A manager vs plant A2 of the same org.
insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, entered_by, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA2'), pg_temp.id('washA2'), pg_temp.id('itemA2'), 9, pg_temp.id('owner'), gen_random_uuid());
select is(array[pg_temp.run_as('owner', $$select 1 from public.finished_goods_entries where plant_id = pg_temp.id('plantA2')$$, true),
                pg_temp.run_as('manager', $$select 1 from public.finished_goods_entries where plant_id = pg_temp.id('plantA2')$$, true),
                pg_temp.run_as('manager', $$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, entered_by, client_id)
                  values (pg_temp.id('orgA'), pg_temp.id('plantA2'), pg_temp.id('washA2'), pg_temp.id('itemA2'), 1, (select auth.uid()), gen_random_uuid())$$)],
  '{1,0,42501}', 'plant A manager cannot read or write plant A2 finished goods (org-wide owner can read)');
select is((select array[pack_size_used, pieces] from public.finished_goods_entries where id = 'f0000000-0000-0000-0000-0000000000a1'),
  array[100, 734], 'pack item: pack size copied from the item; pieces = 7×100 + 34 (generated)');
select is((select shift_instance_id from public.finished_goods_entries where id = 'f0000000-0000-0000-0000-0000000000a1'),
  pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03'), 'set_shift_instance fallback: area''s clock-based instance');
select throws_ok($$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, packs, pieces, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 0, 5, pg_temp.id('owner'), gen_random_uuid())$$,
  '428C9', null, 'pieces is generated, never written');

-- apply_count_mode.
select throws_ok($$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, packs, pack_size_used, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 1, 10, pg_temp.id('owner'), gen_random_uuid())$$,
  'P0001', 'COUNT_MODE_MISMATCH', 'unit item: packs rejected');
select throws_ok($$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, pack_size_used, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 3, 10, pg_temp.id('owner'), gen_random_uuid())$$,
  'P0001', 'COUNT_MODE_MISMATCH', 'unit item: pack_size_used rejected');
select is(pg_temp.as_service($$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, packs, pack_size_used, loose_pieces, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 2, 50, 0, pg_temp.id('manager'), gen_random_uuid())$$), '1',
  'pack item: per-entry pack size override allowed');
select is((select pieces from public.finished_goods_entries where pack_size_used = 50), 100, 'override recorded: 2×50 = 100 pieces');
select throws_ok($$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, packs, loose_pieces, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 0, 0, pg_temp.id('owner'), gen_random_uuid())$$,
  '23514', null, 'packs + loose_pieces > 0');
select throws_ok($$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 100001, pg_temp.id('owner'), gen_random_uuid())$$,
  '23514', null, 'loose_pieces ≤ 100,000');
update public.item_types set pack_size = 50 where id = pg_temp.id('napkin');
select is((select pack_size_used from public.finished_goods_entries where id = 'f0000000-0000-0000-0000-0000000000a1'), 100,
  'past entries keep the pack size they were recorded with');
-- M2 setup guard: an item's count mode is fixed once finished goods exist (deactivate + add a new item).
select throws_ok($$update public.item_types set count_mode = 'unit', pack_size = null where id = pg_temp.id('napkin')$$,
  'P0001', 'VALIDATION_FAILED', 'count mode cannot change once finished goods exist');
-- Extra (b), for rows from before the guard: after a count-mode change, voiding an old row still works;
-- editing its counts does not. The guard is switched off inside this test transaction only.
alter table public.item_types disable trigger item_types_guard_edit;
update public.item_types set count_mode = 'unit', pack_size = null where id = pg_temp.id('napkin');
select lives_ok($$update public.finished_goods_entries set voided_at = now(), voided_by = pg_temp.id('owner'), void_reason = 'test'
  where id = 'f0000000-0000-0000-0000-0000000000a1'$$, 'void of a past pack entry passes after the item became unit-counted');
select throws_ok($$update public.finished_goods_entries set packs = 8 where id = 'f0000000-0000-0000-0000-0000000000a1'$$,
  'P0001', 'COUNT_MODE_MISMATCH', 'changing counts re-validates against the current count mode');
update public.item_types set count_mode = 'pack', pack_size = 100 where id = pg_temp.id('napkin');
alter table public.item_types enable trigger item_types_guard_edit;
select is((select action from public.audit_log where entity_id = 'f0000000-0000-0000-0000-0000000000a1' and action like '%void%'),
  'finished_goods_entries.void', 'voids are audited');

-- v1.3 area consistency + tenant FKs.
select throws_ok($$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, entered_by, client_id, shift_instance_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 1, pg_temp.id('owner'), gen_random_uuid(),
          pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03'))$$, '23503', null,
  'an entry cannot use another area''s shift instance');
select throws_ok($$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, entered_by, client_id, queue_item_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 1, pg_temp.id('owner'), gen_random_uuid(), gen_random_uuid())$$,
  '23503', null, 'queue_item_id must be a queue item of the same plant');
select is(pg_temp.run_as('ownerB', $$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, entered_by, client_id)
  values (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), pg_temp.id('mat'), 1, (select auth.uid()), gen_random_uuid())$$),
  '42501', 'M2: owner B direct insert is denied before any FK or trigger runs');
select is((select shift_instance_id from public.finished_goods_entries f
            where f.id = (select id from public.finished_goods_entries where loose_pieces = 25 limit 1)), pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03'),
  'explicit/fallback shift kept');

-- throttle_writes: more than 120 inserts by one user in 60 s → RATE_LIMITED.
select lives_ok($$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, entered_by, client_id)
  select pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 1, pg_temp.id('nobody'), gen_random_uuid()
    from generate_series(1, 120)$$, '120 finished-goods inserts in a minute are fine');
select throws_ok($$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 1, pg_temp.id('nobody'), gen_random_uuid())$$,
  'P0001', 'RATE_LIMITED', 'the 121st finished-goods insert is rate limited');

-- Security H1: owner B on plant B with packs = 1 and plant A's unit item vs plant A's pack item gets
-- the same 23503 (before: COUNT_MODE_MISMATCH revealed the foreign item's count mode).
select is(array[pg_temp.run_as('ownerB', $$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, packs, entered_by, client_id)
                  values (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), pg_temp.id('mat'), 1, (select auth.uid()), gen_random_uuid())$$),
                pg_temp.run_as('ownerB', $$insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, packs, entered_by, client_id)
                  values (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), pg_temp.id('napkin'), 1, (select auth.uid()), gen_random_uuid())$$)],
  '{42501,42501}', 'H1 finished goods (M2): direct inserts denied before any trigger (RPC pairs: 120)');
-- Architect N1: the entry snapshots the item's wash group; a client value is ignored.
select is(pg_temp.as_service($$insert into public.finished_goods_entries (id, org_id, plant_id, area_id, item_type_id, wash_group_id, loose_pieces, entered_by, client_id)
  values ('f0000000-0000-0000-0000-0000000000a9', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), pg_temp.id('gTowel'), 5, pg_temp.id('manager'), gen_random_uuid())$$),
  '1', 'a writer passes a bogus wash_group_id');
select is((select wash_group_id from public.finished_goods_entries where id = 'f0000000-0000-0000-0000-0000000000a9'), pg_temp.id('gNapkin'),
  'finished goods wash_group_id = the item''s group (client value ignored)');

-- ── washer_cycles: owner/manager/lead/viewer R; display none; M2: writes via start/undo_washer_load only ──
select is(pg_temp.reads($$select 1 from public.washer_cycles where plant_id = pg_temp.id('plantA')$$), '{1,1,1,1,0,0,0,0}', 'washer_cycles R (display: none)');
select is(pg_temp.writes($$insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, load_count, source, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), now(), 1, 'manual', (select auth.uid()), gen_random_uuid())$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'M2: no direct washer_cycles insert for any role (start_washer_load only)');
select is(array[pg_temp.run_as('lead', $$insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, source, entered_by, client_id)
                  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), now(), 'accuflow_csv', (select auth.uid()), gen_random_uuid())$$),
                pg_temp.run_as('lead', $$insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, source, entered_by, client_id)
                  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), now(), 'manual', pg_temp.id('owner'), gen_random_uuid())$$)],
  '{42501,42501}', 'M2: no direct insert of any source, as anyone');
select is(pg_temp.writes($$update public.washer_cycles set load_count = 2$$), '{42501,42501,42501,42501,42501,42501,42501,42501}', 'washer_cycles U denied (security carry-forward: no UPDATE privilege)');
select throws_ok($$delete from public.washer_cycles$$, 'P0001', 'VALIDATION_FAILED', 'prevent_delete on washer cycles');
select is((select shift_instance_id from public.washer_cycles where id = 'f1000000-0000-0000-0000-0000000000a1'),
  pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03'), 'washer load gets its area''s clock instance');
insert into public.washer_cycles (id, org_id, plant_id, area_id, wash_formula_id, started_at, source, entered_by, client_id) values
  ('f1000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('formula'),
   pg_temp.ny('2026-11-03 02:00'), 'manual', pg_temp.id('owner'), gen_random_uuid());
select is((select wash_group_id from public.washer_cycles where id = 'f1000000-0000-0000-0000-0000000000a2'), pg_temp.id('gNapkin'),
  'resolve_group_from_formula copies the formula''s wash group');
select throws_ok($$insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, source, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('groupB'), now(), 'manual', gen_random_uuid())$$,
  '23503', null, 'a washer load cannot use another tenant''s wash group');
select throws_ok($$insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, source, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('groupA2'), now(), 'manual', gen_random_uuid())$$,
  '23503', null, 'a washer load cannot use another plant''s wash group (same org)');
select ok(not exists (select 1 from information_schema.columns where table_schema = 'public'
                       and table_name in ('washer_cycles', 'soil_estimates', 'wash_formulas') and column_name = 'item_type_id'),
  'washroom-side tables reference wash groups, not items');
select throws_ok($$insert into public.washer_cycles (org_id, plant_id, area_id, started_at, source, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), now(), 'manual', gen_random_uuid())$$, '23514', null, 'wash group or formula required');
select throws_ok($$insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, source) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), now(), 'manual')$$, '23514', null, 'N2: manual loads require client_id');
select lives_ok($$insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, source, external_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), now(), 'accuflow_csv', 'row-1')$$, 'imports may omit client_id');
select throws_ok($$insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, source, load_count, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), now(), 'manual', 201, gen_random_uuid())$$, '23514', null, 'load_count 1–200');
select throws_ok($$insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, source, shift_instance_id, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), now(), 'manual', pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03'), gen_random_uuid())$$,
  '23503', null, 'a washer load cannot use another area''s shift instance');
select throws_ok($$insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, source, machine_id, client_id) values
  (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), pg_temp.id('groupB'), now(), 'manual', pg_temp.id('machine'), gen_random_uuid())$$,
  '23503', null, 'a washer load cannot use another plant''s machine');
select lives_ok($$insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, source, entered_by, client_id)
  select pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), now(), 'manual', pg_temp.id('nobody'), gen_random_uuid()
    from generate_series(1, 120)$$, '120 washer inserts in a minute are fine');
select throws_ok($$insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, source, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), now(), 'manual', pg_temp.id('nobody'), gen_random_uuid())$$,
  'P0001', 'RATE_LIMITED', 'the 121st washer insert is rate limited');

-- Architect N1: load_factor_used snapshots the machine's factor; a client value is ignored.
insert into public.machines (id, org_id, plant_id, area_id, name, kind, load_factor) values
  ('60000000-0000-0000-0000-0000000000a7', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Big washer', 'washer', 1.19);
select is(array[pg_temp.as_service($$insert into public.washer_cycles (id, org_id, plant_id, area_id, wash_group_id, machine_id, load_factor_used, started_at, source, entered_by, client_id)
                  values ('f1000000-0000-0000-0000-0000000000a7', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'),
                          '60000000-0000-0000-0000-0000000000a7', 3, now(), 'manual', pg_temp.id('lead'), gen_random_uuid())$$),
                pg_temp.as_service($$insert into public.washer_cycles (id, org_id, plant_id, area_id, wash_group_id, load_factor_used, started_at, source, entered_by, client_id)
                  values ('f1000000-0000-0000-0000-0000000000a8', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'),
                          2, now(), 'manual', pg_temp.id('lead'), gen_random_uuid())$$)],
  '{1,1}', 'a writer passes bogus load_factor_used values');
select is((select array_agg(load_factor_used order by id) from public.washer_cycles
            where id in ('f1000000-0000-0000-0000-0000000000a7', 'f1000000-0000-0000-0000-0000000000a8')),
  array[1.19, 1.00]::numeric[], 'load_factor_used = the machine''s factor, 1.00 without a machine (client values ignored)');

-- ── shift_crew_hours: owner/manager R C U; lead, viewer R ──
select is(pg_temp.reads($$select 1 from public.shift_crew_hours where plant_id = pg_temp.id('plantA')$$), '{1,1,1,1,0,0,0,0}', 'shift_crew_hours R');
select is(pg_temp.writes($$insert into public.shift_crew_hours (org_id, plant_id, shift_instance_id, area_id, crew_count, labor_hours, entered_by)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'),
          (select si.id from public.shift_instances si where si.area_id = pg_temp.id('fin')
              and not exists (select 1 from public.shift_crew_hours h where h.shift_instance_id = si.id) order by si.starts_at limit 1),
          pg_temp.id('fin'), 5, 30, (select auth.uid()))$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'shift_crew_hours C owner/manager');
select is(pg_temp.writes($$update public.shift_crew_hours set crew_count = 6 where plant_id = pg_temp.id('plantA')$$), '{3,3,0,0,0,0,0,0}', 'shift_crew_hours U owner/manager');
select throws_ok($$insert into public.shift_crew_hours (org_id, plant_id, shift_instance_id, area_id, crew_count, labor_hours, entered_by)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-04'), pg_temp.id('wash'), 1, 1, pg_temp.id('owner'))$$,
  '23503', null, 'crew hours area must match the shift instance''s area');

-- ── import_batches: owner/manager/lead R C; viewer R ──
select is(pg_temp.reads($$select 1 from public.import_batches where plant_id = pg_temp.id('plantA')$$), '{1,1,1,1,0,0,0,0}', 'import_batches R');
select is(pg_temp.writes($$insert into public.import_batches (org_id, plant_id, source, created_by)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'accuflow_csv', (select auth.uid()))$$),
  '{1,1,1,42501,42501,42501,42501,42501}', 'import_batches C owner/manager/lead');
select is(pg_temp.writes($$update public.import_batches set status = 'failed'$$), '{0,0,0,0,0,0,0,0}', 'import_batches U denied (Edge Function uses the service role)');

select * from finish();
rollback;
