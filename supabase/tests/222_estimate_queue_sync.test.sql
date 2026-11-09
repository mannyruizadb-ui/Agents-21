-- Estimates fill the washroom queue (owner 2026-11-09, option a; 20261109193413): record_soil_estimate keeps
-- ONE from_estimate queue item per wash group (our own groups only) in step with the group's current
-- estimate: create at the bottom, update in place (position / rush / washer / note kept), cancel at 0, in
-- progress = loads started + estimate loads (done at 0). Manual, rewash and customer items are untouched;
-- idempotent retries never sync twice; the role matrix is unchanged; get_queue exposes from_estimate; the
-- backfill is re-runnable.
begin;
\ir _fixtures.psql
select plan(60);

insert into public.customers (id, org_id, plant_id, name, name_i18n) values
  ('c2000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'AA Test', '{}');
insert into public.wash_groups (id, org_id, plant_id, customer_id, name, active) values
  ('71000000-0000-0000-0000-0000000ee0a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'c2000000-0000-0000-0000-0000000000a1', 'AA towels', true);

-- record_soil_estimate SQL. Each estimate gets entered_at = clock_timestamp() (every RPC in this test runs in
-- one transaction, so now() would tie; a real call is its own transaction), or that minus p_ago (offline).
create function pg_temp.est(p_group uuid, p_qty numeric, p_unit text, p_client uuid default null, p_ago interval default null)
returns text language sql as $$
  select format($q$select public.record_soil_estimate(%L::uuid, %s, %L, %s, p_entered_at => clock_timestamp() - %L::interval)$q$,
                p_group, p_qty, p_unit, coalesce(quote_literal(p_client) || '::uuid', 'gen_random_uuid()'), coalesce(p_ago, '0'));
$$;
-- The open from_estimate item of a group in an area (null when none).
create function pg_temp.ei(p_group uuid, p_area uuid default '30000000-0000-0000-0000-0000000000a1') returns uuid language sql stable as $$
  select q.id from public.queue_items q
   where q.area_id = p_area and q.wash_group_id = p_group and q.from_estimate and q.status in ('queued', 'in_progress');
$$;
create function pg_temp.qrow(p_id uuid) returns text language sql stable as $$
  select row(q.qty, q.unit, q.status, q.loads_started, q.is_rush, q.is_rewash, q.assigned_machine_id is not null, q.note, q.from_estimate)::text
    from public.queue_items q where q.id = p_id;
$$;
grant execute on function pg_temp.ei(uuid, uuid) to authenticated;

-- Existing work: an owner's manual Napkins item, an owner's RUSH Mats item, a manager's Towels rewash, and
-- an AA (customer) item.
select pg_temp.run_as('owner',   $$select public.create_queue_item(pg_temp.id('wash'), 5, 'load', 'e8000000-0000-0000-0000-000000000001', pg_temp.id('gNapkin'))$$);
select pg_temp.run_as('owner',   $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', 'e8000000-0000-0000-0000-000000000002', pg_temp.id('gMat'), p_is_rush => true)$$);
select pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', 'e8000000-0000-0000-0000-000000000003', pg_temp.id('gTowel'), p_is_rewash => true)$$);
select pg_temp.as_service($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id)
                           values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), '71000000-0000-0000-0000-0000000ee0a1', 2, 'bin',
                                   app.queue_edge_position(pg_temp.id('wash'), false, false, null), pg_temp.id('owner'), 'e8000000-0000-0000-0000-000000000004')$$);
select set_config('test.others', (select string_agg(row(q.client_id, q.version, q.qty, q.unit, q.status, q.position, q.from_estimate)::text, ';' order by q.client_id)
                                    from public.queue_items q where q.client_id::text like 'e8000000-%'), true);

-- ══ Structure ════════════════════════════════════════════════════════════
select is((select row(c.is_nullable, c.column_default)::text from information_schema.columns c
            where c.table_schema = 'public' and c.table_name = 'queue_items' and c.column_name = 'from_estimate'),
  '(NO,false)', 'queue_items.from_estimate: boolean not null default false');
select ok((select i.indexdef ~ 'UNIQUE' and i.indexdef ~ '\(area_id, wash_group_id\)' and i.indexdef ~ 'from_estimate'
                  and i.indexdef ~ 'queued' and i.indexdef ~ 'in_progress'
             from pg_indexes i where i.indexname = 'queue_items_one_open_estimate_idx'),
  'partial unique index: one open (queued / in_progress) estimate item per (area, wash group)');
select ok(not has_function_privilege('authenticated', 'app.sync_estimate_queue_item(uuid)', 'execute')
          and not has_function_privilege('anon', 'app.sync_estimate_queue_item(uuid)', 'execute')
          and not has_function_privilege('authenticated', 'app.backfill_estimate_queue_items()', 'execute')
          and not has_function_privilege('anon', 'app.backfill_estimate_queue_items()', 'execute'),
  'the sync and backfill helpers are internal (no client role may execute them)');
select is(pg_temp.reads($$select q.from_estimate from public.queue_items q where q.area_id = pg_temp.id('wash')$$),
  '{4,4,4,4,4,0,0,42501}'::text[],
  'from_estimate is readable wherever queue_items is (column grant; RLS unchanged: open items for manager / lead / viewer / its display)');

-- ══ Role matrix unchanged (owner / manager write; everyone else refused) ═══
select is(pg_temp.writes(pg_temp.est(pg_temp.id('gNapkin'), 2, 'load')),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'record_soil_estimate: owner and manager only (lead, viewer, displays, another tenant refused; anon cannot call)');
select is((select count(*)::int from public.queue_items where from_estimate), 1,
  'the two estimates (owner, then manager) made ONE estimate item; refused callers wrote nothing');
select is((select row(q.qty, q.unit, q.status, q.is_rush, q.is_rewash, q.assigned_machine_id, q.note, q.item_type_id, q.customer_id,
                      q.created_by = pg_temp.id('owner'), q.version)::text
             from public.queue_items q where q.id = pg_temp.ei(pg_temp.id('gNapkin'))),
  '(2.00,load,queued,f,f,,,,,t,1)',
  'created from the first estimate: qty / unit = the estimate''s, normal (not rush / rewash / assigned), no note, created_by = the estimate''s author; the manager''s same 2 loads wrote nothing (version 1)');
select is((select array_agg(q.client_id::text order by q.is_rush desc, q.position) from public.queue_items q
            where q.area_id = pg_temp.id('wash') and q.status in ('queued', 'in_progress')),
  array['e8000000-0000-0000-0000-000000000002', 'e8000000-0000-0000-0000-000000000001', 'e8000000-0000-0000-0000-000000000003',
        'e8000000-0000-0000-0000-000000000004', (select client_id::text from public.queue_items where id = pg_temp.ei(pg_temp.id('gNapkin')))],
  'the estimate item lands at the BOTTOM of the normal items (rush first)');
select is(array[pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gNapkin'))$$),
                pg_temp.run_as('manager', format('select public.cancel_queue_item(%L, 1)', pg_temp.ei(pg_temp.id('gNapkin')))),
                pg_temp.run_as('ownerB', pg_temp.est(pg_temp.id('gNapkin'), 9, 'load'))],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}',
  'other queue edits stay owner-only for managers (create normal work, cancel), and another tenant cannot estimate here');

-- ══ Update in place; idempotent retry ════════════════════════════════════
select is(pg_temp.run_as('manager', pg_temp.est(pg_temp.id('gNapkin'), 3, 'load', 'e9000000-0000-0000-0000-000000000001')), '1',
  'a manager re-estimates Napkins: 3 loads');
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 9, 'load', 'e9000000-0000-0000-0000-000000000001')$$), '1',
  'its retry (same client_id, other values) returns the saved estimate');
select is((select row(q.qty, q.version, q.status)::text from public.queue_items q where q.id = pg_temp.ei(pg_temp.id('gNapkin'))),
  '(3.00,2,queued)', 'not started: qty updated in place, ONE version bump; the retry did not sync again');
select is((select count(*)::int from public.soil_estimates where client_id = 'e9000000-0000-0000-0000-000000000001'), 1,
  'the retry wrote no second estimate');

-- ══ Owner reorders / edits; a re-estimate keeps position, washer, note, rush ═══
select set_config('test.nap', pg_temp.ei(pg_temp.id('gNapkin'))::text, true);
select is(array[
  pg_temp.run_as('owner', format('select public.reorder_queue_item(%L, 2, null)', current_setting('test.nap'))),
  pg_temp.run_as('owner', format($q$select public.update_queue_item(%L, 3, 3, 'load', false, false, 'dock 2', pg_temp.id('machine'))$q$, current_setting('test.nap')))],
  '{1,1}', 'the owner moves the estimate item to the top of the normal work and assigns Washer 1 with a note');
select set_config('test.nap_pos', (select position::text from public.queue_items where id = current_setting('test.nap')::uuid), true);
select is(pg_temp.run_as('manager', pg_temp.est(pg_temp.id('gNapkin'), 4, 'load')), '1', 'a manager re-estimates Napkins: 4 loads');
select is((select row(q.qty, q.unit, q.position::text = current_setting('test.nap_pos'), q.assigned_machine_id = pg_temp.id('machine'), q.note, q.is_rush, q.version)::text
             from public.queue_items q where q.id = current_setting('test.nap')::uuid),
  '(4.00,load,t,t,"dock 2",f,5)', 'same item: new qty, same position (the owner''s order), washer and note kept');
select is((select array_agg(q.client_id::text order by q.is_rush desc, q.position) from public.queue_items q
            where q.area_id = pg_temp.id('wash') and q.status in ('queued', 'in_progress') and not q.is_rush),
  array[(select client_id::text from public.queue_items where id = current_setting('test.nap')::uuid), 'e8000000-0000-0000-0000-000000000001',
        'e8000000-0000-0000-0000-000000000003', 'e8000000-0000-0000-0000-000000000004'],
  'board order still the owner''s');
select is(pg_temp.run_as('owner', format($q$select public.update_queue_item(%L, 5, 4, 'load', true, false, 'dock 2', pg_temp.id('machine'))$q$, current_setting('test.nap'))),
  '1', 'the owner marks it RUSH');
select is(pg_temp.run_as('manager', pg_temp.est(pg_temp.id('gNapkin'), 5, 'load')), '1', 'a manager re-estimates Napkins: 5 loads');
select is(pg_temp.qrow(current_setting('test.nap')::uuid), '(5.00,load,queued,0,t,f,t,"dock 2",t)', 'RUSH kept on a re-estimate');

-- ══ Baskets; unit change before any start ════════════════════════════════
select is(pg_temp.run_as('manager', pg_temp.est(pg_temp.id('gTowel'), 3, 'basket')), '1', 'Towels estimated in baskets (0.5 loads per basket)');
select set_config('test.tow', pg_temp.ei(pg_temp.id('gTowel'))::text, true);
select is(pg_temp.val_as('manager', $$select row(b.qty, b.unit, b.loads_needed, b.from_estimate)::text from public.get_queue(pg_temp.id('wash')) b where b.id = current_setting('test.tow')::uuid$$),
  '(3.00,basket,2,t)', 'a Towels estimate item in baskets (loads_needed = ceil(1.5)); the manager''s Towels REWASH is a different item');
select is(pg_temp.run_as('manager', pg_temp.est(pg_temp.id('gTowel'), 2, 'load')), '1', 'Towels re-estimated in loads');
select is(pg_temp.qrow(current_setting('test.tow')::uuid), '(2.00,load,queued,0,f,f,f,,t)', 'not started: unit and qty follow the estimate');

-- ══ In progress ═════════════════════════════════════════════════════════
select is(pg_temp.run_as('lead', format($q$select public.start_washer_load(pg_temp.id('machine'), 'ea000000-0000-0000-0000-000000000001', %L,
                                          p_confirm_running => true, p_off_queue_reason => 'other')$q$, current_setting('test.tow'))),
  '1', 'a washer start takes one load of the Towels estimate item');
select is(pg_temp.run_as('manager', pg_temp.est(pg_temp.id('gTowel'), 4, 'basket')), '1', 'what is still dirty: 4 baskets (2 loads)');
select is(pg_temp.val_as('manager', $$select row(b.qty, b.unit, b.status, b.loads_started, b.loads_needed, b.loads_remaining)::text
             from public.get_queue(pg_temp.id('wash')) b where b.id = current_setting('test.tow')::uuid$$),
  '(3.00,load,in_progress,1,3,2)', 'in progress: qty = 1 started + 2 estimated, in loads; 2 remain');
select is(pg_temp.run_as('manager', pg_temp.est(pg_temp.id('gTowel'), 0, 'load')), '1', 'Towels cleared (0)');
select is((select row(q.qty, q.unit, q.status, q.loads_started, q.completed_at is not null)::text from public.queue_items q where q.id = current_setting('test.tow')::uuid),
  '(1.00,load,done,1,t)', 'in progress + estimate 0: qty = the loads started → done');
select is(pg_temp.run_as('manager', pg_temp.est(pg_temp.id('gTowel'), 1, 'load')), '1', 'new Towels dirt later: 1 load');
select is((select row(pg_temp.ei(pg_temp.id('gTowel')) <> current_setting('test.tow')::uuid, (select status from public.queue_items where id = current_setting('test.tow')::uuid))::text),
  '(t,done)', 'a NEW estimate item is created; the done one stays done');
select is((select q.id from public.queue_items q where q.area_id = pg_temp.id('wash') and q.status in ('queued', 'in_progress') and not q.is_rush
            order by q.position desc limit 1), pg_temp.ei(pg_temp.id('gTowel')), '… at the bottom of the normal work');

-- In progress with a fraction: Mats get basket estimates (3.5 loads per basket).
select pg_temp.as_service($$update public.wash_groups set loads_per_basket = 3.5, allow_basket_estimates = true where id = pg_temp.id('gMat')$$);
select is(pg_temp.run_as('manager', pg_temp.est(pg_temp.id('gMat'), 2, 'load')), '1', 'Mats: 2 loads (the owner''s RUSH Mats item is separate)');
select set_config('test.mat', pg_temp.ei(pg_temp.id('gMat'))::text, true);
select pg_temp.as_service(format($q$update public.queue_items set loads_started = 2, status = 'in_progress' where id = %L$q$, current_setting('test.mat')));
select is(pg_temp.run_as('manager', pg_temp.est(pg_temp.id('gMat'), 1, 'basket')), '1', 'Mats in progress (2 started), 1 basket still dirty');
select is(pg_temp.val_as('manager', $$select row(b.qty, b.unit, b.status, b.loads_needed, b.loads_remaining)::text from public.get_queue(pg_temp.id('wash')) b where b.id = current_setting('test.mat')::uuid$$),
  '(5.50,load,in_progress,6,4)', 'qty = 2 + 3.5 = 5.5 loads (ceil 6 needed)');
-- No factor any more (defensive path; record_soil_estimate cannot reach it because a basket estimate needs
-- the factor): an older basket estimate synced after the owner removed the factor.
select pg_temp.as_service($$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id, entered_at)
                           values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'), 2, 'basket', pg_temp.id('manager'),
                                   'eb000000-0000-0000-0000-000000000001', clock_timestamp())$$);
select pg_temp.as_service($$update public.wash_groups set allow_basket_estimates = false, loads_per_basket = null where id = pg_temp.id('gMat')$$);
select is((select app.sync_estimate_queue_item(e.id) from public.soil_estimates e where e.client_id = 'eb000000-0000-0000-0000-000000000001'),
  current_setting('test.mat')::uuid, 'the sync runs on the same Mats item');
select is(pg_temp.val_as('manager', $$select row(b.qty, b.unit, b.status, b.loads_started, coalesce(b.loads_needed::text, 'null'))::text
             from public.get_queue(pg_temp.id('wash')) b where b.id = current_setting('test.mat')::uuid$$),
  '(2.00,basket,in_progress,2,null)', 'no factor: the estimate''s own qty / unit (never added to loads); loads_needed null, so it is closed by hand');

-- ══ Cancel path; nothing to do at 0 ═════════════════════════════════════
select is(pg_temp.run_as('owner', format('select public.update_queue_item(%L, 7, 5, ''load'', false, false, ''dock 2'', null)', current_setting('test.nap'))), '1',
  'the owner takes RUSH off Napkins again');
select is(pg_temp.run_as('manager', pg_temp.est(pg_temp.id('gNapkin'), 0, 'load')), '1', 'Napkins cleared (0) before any start');
select is((select row(q.status, pg_temp.ei(pg_temp.id('gNapkin')) is null)::text from public.queue_items q where q.id = current_setting('test.nap')::uuid),
  '(cancelled,t)', 'not started + estimate 0: the estimate item is cancelled (never deleted)');
select set_config('test.n', (select count(*)::text from public.queue_items), true);
select is(array[pg_temp.run_as('manager', pg_temp.est(pg_temp.id('gNapkin'), 0, 'load')),
                (select count(*)::text from public.queue_items)],
  array['1', current_setting('test.n')], 'estimate 0 with no open estimate item: nothing is written to the queue');

-- ══ Not synced: customer groups, a stale offline estimate ═══════════════
select is(pg_temp.run_as('manager', pg_temp.est('71000000-0000-0000-0000-0000000ee0a1', 2, 'load')), '1', 'an estimate for an AA (customer) group still saves');
select is((select count(*)::int from public.queue_items where wash_group_id = '71000000-0000-0000-0000-0000000ee0a1' and from_estimate), 0,
  'customer groups get no estimate item (AA keeps its delivery flow)');
select is(pg_temp.run_as('manager', pg_temp.est(pg_temp.id('gTowel'), 7, 'load', p_ago => '1 hour')), '1',
  'an offline Towels estimate from an hour ago arrives late');
select is(pg_temp.qrow(pg_temp.ei(pg_temp.id('gTowel'))), '(1.00,load,queued,0,f,f,f,,t)',
  'it is not the current estimate, so the queue keeps following the newer one');
select is(pg_temp.as_service($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id, from_estimate)
                              values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gTowel'), 1, 'load', 99, pg_temp.id('owner'), gen_random_uuid(), true)$$),
  '23505', 'a second open estimate item for the same group is rejected by the unique index');

-- ══ Undo next to a newer estimate item (security review 2026-11-09, Medium) ═══
select set_config('test.tow2', pg_temp.ei(pg_temp.id('gTowel'))::text, true);
select is(pg_temp.run_as('lead', format($q$select public.start_washer_load(pg_temp.id('machine'), 'ea000000-0000-0000-0000-000000000002', %L,
                                          p_confirm_running => true, p_off_queue_reason => 'other')$q$, current_setting('test.tow2'))),
  '1', 'a start takes the last load of the Towels estimate item (1 load) …');
select is(pg_temp.qrow(current_setting('test.tow2')::uuid), '(1.00,load,done,1,f,f,f,,t)', '… so it is done');
select is(pg_temp.run_as('manager', pg_temp.est(pg_temp.id('gTowel'), 2, 'load')), '1', 'new Towels dirt: 2 loads → a new estimate item');
select set_config('test.tow3', pg_temp.ei(pg_temp.id('gTowel'))::text, true);
select set_config('test.cyc', (select id::text from public.washer_cycles where client_id = 'ea000000-0000-0000-0000-000000000002'), true);
select is(pg_temp.run_as('lead', format('select public.undo_washer_load(%L)', current_setting('test.cyc'))),
  '1', 'the washman UNDOes that start within 5 minutes: no 23505, a clean result');
select is((select row(w.voided_at is not null, w.void_reason)::text from public.washer_cycles w where w.client_id = 'ea000000-0000-0000-0000-000000000002'),
  '(t,undo)', 'the cycle is voided');
select is(array[pg_temp.qrow(current_setting('test.tow2')::uuid), pg_temp.qrow(current_setting('test.tow3')::uuid),
                (select version::text from public.queue_items where id = current_setting('test.tow3')::uuid)],
  array['(1.00,load,done,0,f,f,f,,t)', '(2.00,load,queued,0,f,f,f,,t)', '1'],
  'the old item gets its load back but STAYS DONE (a newer open estimate item exists); the new item is untouched');
select is(pg_temp.run_as('lead', format('select public.undo_washer_load(%L)', current_setting('test.cyc'))),
  '1', 'a retry of the undo is idempotent');

-- ══ Other plant; manual items untouched; get_queue; audit ═══════════════
select is(pg_temp.run_as('owner', pg_temp.est(pg_temp.id('groupA2'), 2, 'load')), '1', 'an org-wide owner estimates in plant A2');
select is((select row(q.area_id = pg_temp.id('washA2'), q.qty, q.from_estimate)::text from public.queue_items q where q.wash_group_id = pg_temp.id('groupA2')),
  '(t,2.00,t)', 'the item goes to THAT plant''s washroom');
select is((select string_agg(row(q.client_id, q.version, q.qty, q.unit, q.status, q.position, q.from_estimate)::text, ';' order by q.client_id)
             from public.queue_items q where q.client_id::text like 'e8000000-%'),
  current_setting('test.others'), 'the manual, rush, rewash and customer items were never touched (version, qty, status, position)');
select is(array[pg_temp.val_as('manager', $$select string_agg(b.from_estimate::text, ',' order by b.is_rush desc, b."position") from public.get_queue(pg_temp.id('wash')) b$$),
                pg_temp.val_as('display', $$select count(*) filter (where b.from_estimate) from public.get_queue(pg_temp.id('wash')) b$$)],
  array['false,false,false,false,true,true', '2'],
  'get_queue exposes from_estimate (manager and the washroom display)');
select is((select array_agg(a.action order by a.id) from public.audit_log a where a.entity = 'queue_items' and a.entity_id = current_setting('test.tow')::uuid),
  array['queue_items.insert', 'queue_items.update', 'queue_items.update', 'queue_items.update', 'queue_items.update', 'queue_items.update'],
  'estimate items are audited like every queue write (insert; unit change; start; in-progress qty; qty at 0; done)');

-- ══ Backfill ═════════════════════════════════════════════════════════════
-- An estimate saved without a sync (as before this migration): Napkins 3 loads, no open estimate item.
select pg_temp.as_service($$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id, entered_at)
                           values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 3, 'load', pg_temp.id('manager'),
                                   'ec000000-0000-0000-0000-000000000001', clock_timestamp())$$);
select is(array[app.backfill_estimate_queue_items(), app.backfill_estimate_queue_items()], '{1,0}',
  'backfill: one item for the current Napkins estimate (Towels / Mats / A2 already have one, AA is a customer group, 0 estimates need none); a re-run creates nothing');
select is((select row(q.qty, q.unit, q.status, q.created_by = pg_temp.id('manager'), q.is_rush, q.assigned_machine_id)::text
             from public.queue_items q where q.id = pg_temp.ei(pg_temp.id('gNapkin'))),
  '(3.00,load,queued,t,f,)', 'the backfilled item: the estimate''s qty / unit, created_by = its author, normal and unassigned');

select * from finish();
rollback;
