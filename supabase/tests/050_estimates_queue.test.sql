-- B1/C1–C4: soil_estimates (append-only), queue_items (transitions, versions, no deletes).
-- M2 (ADR 001 option B): clients no longer write these tables directly (42501 for every role); the
-- write RPCs are tested in 100_queue_rpcs and 120_entry_rpcs. Trigger rules are tested here as the
-- service role (auth.uid() null), which is how the definer RPCs reach the table.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(51);

insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 4, 'load',   pg_temp.id('manager'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gTowel'),  6, 'basket', pg_temp.id('manager'), gen_random_uuid()),
  (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('groupB'),  1, 'load',   pg_temp.id('ownerB'),  gen_random_uuid());

-- soil_estimates: owner/manager/lead R C; viewer R; display R (plant-wide).
select is(pg_temp.reads($$select 1 from public.soil_estimates where plant_id = pg_temp.id('plantA')$$), '{2,2,2,2,2,0,0,0}', 'soil_estimates R');
select is(pg_temp.writes($$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 3, 'load', (select auth.uid()), gen_random_uuid())$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'M2: no direct soil_estimates insert for any role (record_soil_estimate only)');
select is(pg_temp.run_as('lead', $$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 3, 'load', pg_temp.id('owner'), gen_random_uuid())$$),
  '42501', 'entered_by is pinned to the caller');
select is(pg_temp.run_as('lead', $$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('groupB'), 3, 'load', (select auth.uid()), gen_random_uuid())$$),
  '42501', 'cross-tenant estimate insert denied');
select is(pg_temp.run_as('ownerB', $$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 3, 'basket', (select auth.uid()), gen_random_uuid())$$),
  '42501', 'security M2: check_estimate_unit is not a cross-tenant oracle');
select is(pg_temp.writes($$update public.soil_estimates set note = 'x' where plant_id = pg_temp.id('plantA')$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'soil_estimates U denied for every role (no privilege)');
select is(pg_temp.writes($$delete from public.soil_estimates where plant_id = pg_temp.id('plantA')$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'soil_estimates delete denied for every role (no privilege)');
select throws_ok($$update public.soil_estimates set qty = 1$$, 'P0001', 'VALIDATION_FAILED', 'prevent_mutation: append-only even for the service role');
select throws_ok($$delete from public.soil_estimates$$, 'P0001', 'VALIDATION_FAILED', 'prevent_mutation: no deletes');
select throws_ok($$truncate public.soil_estimates$$, 'P0001', 'VALIDATION_FAILED', 'L2: TRUNCATE blocked by trigger');
select is(pg_temp.run_as('owner', $$truncate public.queue_items$$), '42501', 'L2: clients have no TRUNCATE privilege');
select throws_ok($$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 3, 'basket', pg_temp.id('lead'), gen_random_uuid())$$,
  'P0001', 'VALIDATION_FAILED', 'basket rejected when the wash group has no allow_basket_estimates');
select throws_ok($$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 3, 'piece', pg_temp.id('lead'), gen_random_uuid())$$,
  '23514', null, 'estimates are in load or basket only');
select throws_ok($$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 10000.01, 'load', pg_temp.id('lead'), gen_random_uuid())$$,
  '23514', null, 'estimate qty ≤ 10,000');
select throws_ok($$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 2, 'lbs', pg_temp.id('lead'), gen_random_uuid())$$,
  '22P02', null, 'no weight units exist');
select throws_ok($$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('groupB'), 2, 'load', pg_temp.id('lead'), gen_random_uuid())$$,
  '23503', null, 'estimate wash group must belong to the plant');
select throws_ok($$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
  select org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id from public.soil_estimates limit 1$$,
  '23505', null, 'client_id is unique (idempotency)');

-- queue_items: owner/manager R C U; lead, viewer R; display R own area only.
insert into public.queue_items (id, org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position, created_by, client_id) values
  ('e0000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), pg_temp.id('napkin'), 4, 'load', 1, pg_temp.id('manager'), gen_random_uuid()),
  ('e0000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('gMat'), pg_temp.id('mat'), 10, 'piece', 1, pg_temp.id('manager'), gen_random_uuid()),
  ('e0000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), pg_temp.id('groupB'), pg_temp.id('itemB'), 1, 'load', 1, pg_temp.id('ownerB'), gen_random_uuid());

select is(pg_temp.reads($$select 1 from public.queue_items where plant_id = pg_temp.id('plantA')$$), '{2,2,2,2,1,0,0,0}', 'queue_items R (display: own area)');
select is(pg_temp.run_as('display', $$select 1 from public.queue_items where area_id = pg_temp.id('fin')$$, true), '0', 'display cannot read another area''s queue');
select is(pg_temp.writes($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position, created_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), pg_temp.id('napkin'), 1, 'load', 99, (select auth.uid()), gen_random_uuid())$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'M2: no direct queue_items insert for any role (queue RPCs only)');
select is(pg_temp.writes($$update public.queue_items set note = 'n' where id = 'e0000000-0000-0000-0000-0000000000a1'$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'M2: no direct queue_items update for any role (queue RPCs only)');
update public.queue_items set note = 'n' where id = 'e0000000-0000-0000-0000-0000000000a1';
update public.queue_items set note = 'm' where id = 'e0000000-0000-0000-0000-0000000000a1';
select is((select version from public.queue_items where id = 'e0000000-0000-0000-0000-0000000000a1'),
  3, 'bump_queue_version: version +1 per update');
select is(pg_temp.writes($$delete from public.queue_items where plant_id = pg_temp.id('plantA')$$), '{42501,42501,42501,42501,42501,42501,42501,42501}', 'queue_items delete denied for every role (no privilege)');
select throws_ok($$delete from public.queue_items where id = 'e0000000-0000-0000-0000-0000000000a1'$$, 'P0001', 'VALIDATION_FAILED',
  'prevent_delete: queue items are cancelled, not deleted');
select throws_ok($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position, created_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('washB'), pg_temp.id('gNapkin'), pg_temp.id('napkin'), 1, 'load', 1, pg_temp.id('owner'), gen_random_uuid())$$,
  '23503', null, 'queue area must belong to the plant');
select throws_ok($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position, created_by)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), pg_temp.id('napkin'), 1, 'load', 1, pg_temp.id('owner'))$$,
  '23502', null, 'N2: queue items require client_id');

-- Wash groups (owner 2026-11-01): washroom work is per group; an optional item must be in the group.
select lives_ok($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gMat'), 3, 'load', 5, pg_temp.id('manager'), gen_random_uuid())$$,
  'group-level queue item (no item) in loads');
select throws_ok($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('groupB'), 1, 'load', 1, pg_temp.id('owner'), gen_random_uuid())$$,
  '23503', null, 'queue wash group must belong to the plant (other tenant)');
select throws_ok($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('groupA2'), 1, 'load', 1, pg_temp.id('owner'), gen_random_uuid())$$,
  '23503', null, 'queue wash group must belong to the plant (same org, other plant)');
select throws_ok($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position, created_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('gMat'), pg_temp.id('napkin'), 3, 'pack', 5, pg_temp.id('manager'), gen_random_uuid())$$,
  'P0001', 'VALIDATION_FAILED', 'queue item must be in the row''s wash group');
select throws_ok($$update public.queue_items set wash_group_id = pg_temp.id('gMat') where id = 'e0000000-0000-0000-0000-0000000000a1'$$,
  'P0001', 'VALIDATION_FAILED', 'changing the group away from the item''s group is rejected');
select is(pg_temp.run_as('ownerB', $$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position, created_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gMat'), pg_temp.id('napkin'), 1, 'load', 1, (select auth.uid()), gen_random_uuid())$$),
  '42501', 'security M2: check_queue_item_group is not a cross-tenant oracle');
select throws_ok($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('gMat'), 10, 'piece', 1, pg_temp.id('owner'), gen_random_uuid())$$,
  '23514', null, 'piece/pack queue quantities need an item');
select throws_ok($$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('groupA2'), 2, 'load', pg_temp.id('lead'), gen_random_uuid())$$,
  '23503', null, 'estimate wash group must belong to the plant (same org, other plant)');
select lives_ok($$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gTowel'), 3, 'basket', pg_temp.id('lead'), gen_random_uuid())$$,
  'basket estimate accepted for a group that allows baskets');

-- Security H1: a caller on their OWN plant gets the same answer for any foreign reference, whatever
-- the foreign row's settings (no error-code oracle). Pairs differ only in the foreign row's state.
select is(array[pg_temp.run_as('ownerB', $$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position, created_by, client_id)
                  values (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), pg_temp.id('gNapkin'), pg_temp.id('napkin'), 1, 'load', 1, (select auth.uid()), gen_random_uuid())$$),
                pg_temp.run_as('ownerB', $$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position, created_by, client_id)
                  values (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), pg_temp.id('gMat'), pg_temp.id('napkin'), 1, 'load', 1, (select auth.uid()), gen_random_uuid())$$)],
  '{42501,42501}', 'H1 queue (M2): owner B direct inserts are denied before any trigger runs (RPC pairs: 100)');
select is(array[pg_temp.run_as('ownerB', $$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
                  values (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('gTowel'), 1, 'basket', (select auth.uid()), gen_random_uuid())$$),
                pg_temp.run_as('ownerB', $$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
                  values (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('gNapkin'), 1, 'basket', (select auth.uid()), gen_random_uuid())$$)],
  '{42501,42501}', 'H1 estimate (M2): owner B direct inserts are denied before any trigger runs (RPC pairs: 120)');
-- Same org, other plant: the plant A manager probing plant A2.
insert into public.wash_groups (id, org_id, plant_id, name, allow_basket_estimates, loads_per_basket) values
  ('71000000-0000-0000-0000-0000000000c2', pg_temp.id('orgA'), pg_temp.id('plantA2'), 'A2 baskets', true, 0.5);
select is(array[pg_temp.run_as('manager', $$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position, created_by, client_id)
                  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('groupA2'), pg_temp.id('itemA2'), 1, 'load', 1, (select auth.uid()), gen_random_uuid())$$),
                pg_temp.run_as('manager', $$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position, created_by, client_id)
                  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gMat'), pg_temp.id('itemA2'), 1, 'load', 1, (select auth.uid()), gen_random_uuid())$$)],
  '{42501,42501}', 'H1 queue, same org (M2): direct inserts denied for the manager too');
select is(array[pg_temp.run_as('manager', $$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
                  values (pg_temp.id('orgA'), pg_temp.id('plantA'), '71000000-0000-0000-0000-0000000000c2', 1, 'basket', (select auth.uid()), gen_random_uuid())$$),
                pg_temp.run_as('manager', $$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
                  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('groupA2'), 1, 'basket', (select auth.uid()), gen_random_uuid())$$)],
  '{42501,42501}', 'H1 estimate, same org (M2): direct inserts denied for the manager too');
-- N4 convenience: a queue item given only an item gets the item's wash group.
select lives_ok($$insert into public.queue_items (id, org_id, plant_id, area_id, item_type_id, qty, unit, position, created_by, client_id)
  values ('e0000000-0000-0000-0000-0000000000a5', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 2, 'pack', 6, pg_temp.id('manager'), gen_random_uuid())$$,
  'queue item with only an item is accepted');
select is((select wash_group_id from public.queue_items where id = 'e0000000-0000-0000-0000-0000000000a5'), pg_temp.id('gNapkin'),
  'its wash_group_id is filled from the item');

-- §4.9 transitions (as the service role; clients go through set_queue_item_status / cancel_queue_item).
select lives_ok($$update public.queue_items set status = 'in_progress' where id = 'e0000000-0000-0000-0000-0000000000a1'$$, 'queued → in_progress');
select ok((select started_at is not null and completed_at is null from public.queue_items where id = 'e0000000-0000-0000-0000-0000000000a1'), 'started_at set');
select lives_ok($$update public.queue_items set status = 'done' where id = 'e0000000-0000-0000-0000-0000000000a1'$$, 'in_progress → done');
select ok((select completed_at is not null from public.queue_items where id = 'e0000000-0000-0000-0000-0000000000a1'), 'completed_at set');
select throws_ok($$update public.queue_items set status = 'queued' where id = 'e0000000-0000-0000-0000-0000000000a1'$$,
  'P0001', 'INVALID_STATUS_TRANSITION', 'done → queued rejected');
select throws_ok($$update public.queue_items set status = 'done' where id = 'e0000000-0000-0000-0000-0000000000a2'$$,
  'P0001', 'INVALID_STATUS_TRANSITION', 'queued → done rejected (must start first)');
select lives_ok($$update public.queue_items set status = 'cancelled' where id = 'e0000000-0000-0000-0000-0000000000a2'$$, 'queued → cancelled');
select throws_ok($$update public.queue_items set status = 'in_progress' where id = 'e0000000-0000-0000-0000-0000000000a2'$$,
  'P0001', 'INVALID_STATUS_TRANSITION', 'cancelled → in_progress rejected');
select is((select count(*)::int from public.audit_log where entity = 'queue_items' and entity_id = 'e0000000-0000-0000-0000-0000000000a1'),
  5, 'queue changes are audited (insert + 4 successful updates)');
select is((select count(*)::int from public.audit_log where entity = 'soil_estimates' and plant_id = pg_temp.id('plantA')),
  3, 'estimates are audited on insert (2 fixtures + 1 basket estimate)');

select * from finish();
rollback;
