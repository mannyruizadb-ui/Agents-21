-- B1/C1–C4: soil_estimates (append-only), queue_items (transitions, versions, no deletes).
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(36);

insert into public.soil_estimates (org_id, plant_id, item_type_id, qty, unit, entered_by, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 4, 'load',   pg_temp.id('manager'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('towel'),  6, 'basket', pg_temp.id('manager'), gen_random_uuid()),
  (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('itemB'),  1, 'load',   pg_temp.id('ownerB'),  gen_random_uuid());

-- soil_estimates: owner/manager/lead R C; viewer R; display R (plant-wide).
select is(pg_temp.reads($$select 1 from public.soil_estimates where plant_id = pg_temp.id('plantA')$$), '{2,2,2,2,2,0,0,0}', 'soil_estimates R');
select is(pg_temp.writes($$insert into public.soil_estimates (org_id, plant_id, item_type_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 3, 'load', (select auth.uid()), gen_random_uuid())$$),
  '{1,1,1,42501,42501,42501,42501,42501}', 'soil_estimates C owner/manager/lead (display cannot write)');
select is(pg_temp.run_as('lead', $$insert into public.soil_estimates (org_id, plant_id, item_type_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 3, 'load', pg_temp.id('owner'), gen_random_uuid())$$),
  '42501', 'entered_by is pinned to the caller');
select is(pg_temp.run_as('lead', $$insert into public.soil_estimates (org_id, plant_id, item_type_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('itemB'), 3, 'load', (select auth.uid()), gen_random_uuid())$$),
  '42501', 'cross-tenant estimate insert denied');
select is(pg_temp.run_as('ownerB', $$insert into public.soil_estimates (org_id, plant_id, item_type_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 3, 'basket', (select auth.uid()), gen_random_uuid())$$),
  '42501', 'security M2: check_estimate_unit is not a cross-tenant oracle');
select is(pg_temp.writes($$update public.soil_estimates set note = 'x' where plant_id = pg_temp.id('plantA')$$),
  '{0,0,0,0,0,0,0,0}', 'soil_estimates U denied for every role');
select is(pg_temp.writes($$delete from public.soil_estimates where plant_id = pg_temp.id('plantA')$$),
  '{0,0,0,0,0,0,0,0}', 'soil_estimates delete denied for every role');
select throws_ok($$update public.soil_estimates set qty = 1$$, 'P0001', 'VALIDATION_FAILED', 'prevent_mutation: append-only even for the service role');
select throws_ok($$delete from public.soil_estimates$$, 'P0001', 'VALIDATION_FAILED', 'prevent_mutation: no deletes');
select throws_ok($$truncate public.soil_estimates$$, 'P0001', 'VALIDATION_FAILED', 'L2: TRUNCATE blocked by trigger');
select is(pg_temp.run_as('owner', $$truncate public.queue_items$$), '42501', 'L2: clients have no TRUNCATE privilege');
select is(pg_temp.run_as('lead', $$insert into public.soil_estimates (org_id, plant_id, item_type_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 3, 'basket', (select auth.uid()), gen_random_uuid())$$),
  'VALIDATION_FAILED', 'basket rejected when the item has no allow_basket_estimates');
select throws_ok($$insert into public.soil_estimates (org_id, plant_id, item_type_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 3, 'piece', pg_temp.id('lead'), gen_random_uuid())$$,
  '23514', null, 'estimates are in load or basket only');
select throws_ok($$insert into public.soil_estimates (org_id, plant_id, item_type_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 10000.01, 'load', pg_temp.id('lead'), gen_random_uuid())$$,
  '23514', null, 'estimate qty ≤ 10,000');
select throws_ok($$insert into public.soil_estimates (org_id, plant_id, item_type_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 2, 'lbs', pg_temp.id('lead'), gen_random_uuid())$$,
  '22P02', null, 'no weight units exist');
select throws_ok($$insert into public.soil_estimates (org_id, plant_id, item_type_id, qty, unit, entered_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('itemB'), 2, 'load', pg_temp.id('lead'), gen_random_uuid())$$,
  '23503', null, 'estimate item must belong to the plant');
select throws_ok($$insert into public.soil_estimates (org_id, plant_id, item_type_id, qty, unit, entered_by, client_id)
  select org_id, plant_id, item_type_id, qty, unit, entered_by, client_id from public.soil_estimates limit 1$$,
  '23505', null, 'client_id is unique (idempotency)');

-- queue_items: owner/manager R C U; lead, viewer R; display R own area only.
insert into public.queue_items (id, org_id, plant_id, area_id, item_type_id, qty, unit, position, created_by, client_id) values
  ('e0000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('napkin'), 4, 'load', 1, pg_temp.id('manager'), gen_random_uuid()),
  ('e0000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 10, 'piece', 1, pg_temp.id('manager'), gen_random_uuid()),
  ('e0000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), pg_temp.id('itemB'), 1, 'load', 1, pg_temp.id('ownerB'), gen_random_uuid());

select is(pg_temp.reads($$select 1 from public.queue_items where plant_id = pg_temp.id('plantA')$$), '{2,2,2,2,1,0,0,0}', 'queue_items R (display: own area)');
select is(pg_temp.run_as('display', $$select 1 from public.queue_items where area_id = pg_temp.id('fin')$$, true), '0', 'display cannot read another area''s queue');
select is(pg_temp.writes($$insert into public.queue_items (org_id, plant_id, area_id, item_type_id, qty, unit, position, created_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('napkin'), 1, 'load', 99, (select auth.uid()), gen_random_uuid())$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'queue_items C owner/manager');
select is(pg_temp.writes($$update public.queue_items set note = 'n' where id = 'e0000000-0000-0000-0000-0000000000a1'$$),
  '{1,1,0,0,0,0,0,0}', 'queue_items U owner/manager (lead status changes come via RPC in M2)');
select is((select array[version::text, updated_by::text] from public.queue_items where id = 'e0000000-0000-0000-0000-0000000000a1'),
  array['3', pg_temp.id('manager')::text], 'bump_queue_version: version +1 per update, updated_by = caller');
select is(pg_temp.writes($$delete from public.queue_items where plant_id = pg_temp.id('plantA')$$), '{0,0,0,0,0,0,0,0}', 'queue_items delete denied for every role');
select throws_ok($$delete from public.queue_items where id = 'e0000000-0000-0000-0000-0000000000a1'$$, 'P0001', 'VALIDATION_FAILED',
  'prevent_delete: queue items are cancelled, not deleted');
select throws_ok($$insert into public.queue_items (org_id, plant_id, area_id, item_type_id, qty, unit, position, created_by, client_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('washB'), pg_temp.id('napkin'), 1, 'load', 1, pg_temp.id('owner'), gen_random_uuid())$$,
  '23503', null, 'queue area must belong to the plant');
select throws_ok($$insert into public.queue_items (org_id, plant_id, area_id, item_type_id, qty, unit, position, created_by)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('napkin'), 1, 'load', 1, pg_temp.id('owner'))$$,
  '23502', null, 'N2: queue items require client_id');

-- §4.9 transitions: queued → in_progress → done; queued/in_progress → cancelled.
select is(pg_temp.run_as('manager', $$update public.queue_items set status = 'in_progress' where id = 'e0000000-0000-0000-0000-0000000000a1'$$), '1', 'queued → in_progress');
select ok((select started_at is not null and completed_at is null from public.queue_items where id = 'e0000000-0000-0000-0000-0000000000a1'), 'started_at set');
select is(pg_temp.run_as('manager', $$update public.queue_items set status = 'done' where id = 'e0000000-0000-0000-0000-0000000000a1'$$), '1', 'in_progress → done');
select ok((select completed_at is not null from public.queue_items where id = 'e0000000-0000-0000-0000-0000000000a1'), 'completed_at set');
select is(pg_temp.run_as('manager', $$update public.queue_items set status = 'queued' where id = 'e0000000-0000-0000-0000-0000000000a1'$$),
  'INVALID_STATUS_TRANSITION', 'done → queued rejected');
select is(pg_temp.run_as('manager', $$update public.queue_items set status = 'done' where id = 'e0000000-0000-0000-0000-0000000000a2'$$),
  'INVALID_STATUS_TRANSITION', 'queued → done rejected (must start first)');
select is(pg_temp.run_as('manager', $$update public.queue_items set status = 'cancelled' where id = 'e0000000-0000-0000-0000-0000000000a2'$$), '1', 'queued → cancelled');
select is(pg_temp.run_as('manager', $$update public.queue_items set status = 'in_progress' where id = 'e0000000-0000-0000-0000-0000000000a2'$$),
  'INVALID_STATUS_TRANSITION', 'cancelled → in_progress rejected');
select is((select count(*)::int from public.audit_log where entity = 'queue_items' and entity_id = 'e0000000-0000-0000-0000-0000000000a1'),
  5, 'queue changes are audited (insert + 4 updates)');
select is((select count(*)::int from public.audit_log where entity = 'soil_estimates' and plant_id = pg_temp.id('plantA')),
  5, 'estimates are audited on insert');

select * from finish();
rollback;
