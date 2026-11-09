-- AA Linen products and rights (owner 2026-11-07; 20261107021214, 20261107021216): customer wash groups
-- are owner-only for any column, owners edit any group's formula, leads and displays read customers,
-- void_customer_delivery (owner/manager; once; cancels only never-started queue items), the AA data, and
-- the soap reason's Spanish label. Matrix arrays: [owner, manager, lead, viewer, display,
-- display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(23);

insert into public.customers (id, org_id, plant_id, name) values
  ('c1000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'AA Test'),
  ('c1000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), 'B Customer');
insert into public.wash_groups (id, org_id, plant_id, customer_id, name, loads_per_bin, allow_bin_estimates) values
  ('71000000-0000-0000-0000-0000000aa0a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1', 'AA towels', 2, true),
  ('71000000-0000-0000-0000-0000000aa0a2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1', 'AA aprons', null, false),
  ('71000000-0000-0000-0000-0000000aa0a3', pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1', 'AA napkins', null, false);
insert into public.wash_formulas (id, org_id, plant_id, external_no, name, cycle_minutes) values
  ('80000000-0000-0000-0000-0000000000a9', pg_temp.id('orgA'), pg_temp.id('plantA'), '9', 'Test formula 9', 40);
create function pg_temp.d(p text) returns uuid language sql stable security definer as $$
  select id from public.customer_deliveries where client_id = ('d7000000-0000-0000-0000-00000000000' || p)::uuid;
$$;
create function pg_temp.qi(p text, n int) returns uuid language sql stable security definer as $$
  select l.queue_item_id from public.customer_delivery_lines l where l.delivery_id = pg_temp.d(p) and l.line_no = n;
$$;
grant execute on function pg_temp.d(text), pg_temp.qi(text, int) to authenticated, anon;
-- A delivery of 3 lines (AA towels 1 bin = 2 loads, aprons 1 bin, napkins 1 bin) by the manager.
select pg_temp.run_as('manager', $$select public.record_customer_delivery(pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1',
  '[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":1},{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a2","bins":1},{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a3","bins":1}]',
  'd7000000-0000-0000-0000-000000000001')$$);
select pg_temp.run_as('owner', $$select public.record_customer_delivery(pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1',
  '[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a2","bins":2}]', 'd7000000-0000-0000-0000-000000000002')$$);

-- ══ Customer groups: owner-only, any column ══════════════════════════════
select is(array[
  pg_temp.run_as('manager', $$update public.wash_groups set sort_order = 7 where id = '71000000-0000-0000-0000-0000000aa0a1'$$),
  pg_temp.run_as('manager', $$update public.wash_groups set wash_formula_id = pg_temp.id('formula') where id = '71000000-0000-0000-0000-0000000aa0a1'$$),
  pg_temp.run_as('manager', $$update public.wash_groups set name_i18n = '{"es":"Toallas AA"}' where id = '71000000-0000-0000-0000-0000000aa0a1'$$),
  pg_temp.run_as('manager', $$update public.wash_groups set active = false where id = '71000000-0000-0000-0000-0000000aa0a1'$$),
  pg_temp.run_as('manager', $$insert into public.wash_groups (org_id, plant_id, customer_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1', 'AA mats')$$)],
  '{0,0,0,0,NOT_AUTHORIZED}',
  'a manager cannot insert a customer group or update any column of one (sort, formula, name, active; since 2026-11-09 owner-only RLS: no rows)');
select is(array[
  pg_temp.run_as('manager', $$update public.wash_groups set sort_order = 7, wash_formula_id = pg_temp.id('formula') where id = pg_temp.id('gNapkin')$$),
  pg_temp.run_as('lead', $$update public.wash_groups set sort_order = 8 where id = '71000000-0000-0000-0000-0000000aa0a1'$$),
  pg_temp.run_as('ownerB', $$update public.wash_groups set sort_order = 8 where id = '71000000-0000-0000-0000-0000000aa0a1'$$)],
  '{0,0,0}', 'since 2026-11-09 managers do not edit our own groups either; leads and other tenants update nothing (RLS)');
select is(array[
  pg_temp.run_as('owner', $$update public.wash_groups set wash_formula_id = '80000000-0000-0000-0000-0000000000a9', sort_order = 3, name_i18n = '{"es":"Toallas AA"}' where id = '71000000-0000-0000-0000-0000000aa0a1'$$),
  pg_temp.run_as('owner', $$update public.wash_groups set wash_formula_id = '80000000-0000-0000-0000-0000000000a9' where id = pg_temp.id('gMat')$$),
  pg_temp.run_as('owner', $$insert into public.wash_groups (org_id, plant_id, customer_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1', 'AA mats')$$)],
  '{1,1,1}', 'owners edit any group''s formula (ours and the customer''s) and add customer groups');
select is((select wash_formula_id from public.wash_groups where id = '71000000-0000-0000-0000-0000000aa0a1'), '80000000-0000-0000-0000-0000000000a9'::uuid,
  'the customer group''s formula is now formula 9');
select is(pg_temp.run_as('owner', $$update public.wash_groups set wash_formula_id = gen_random_uuid() where id = '71000000-0000-0000-0000-0000000aa0a1'$$), '23503',
  'a formula must exist (FK)');

-- ══ customers: leads and displays read ═══════════════════════════════════
select is(pg_temp.reads($$select name from public.customers where id = 'c1000000-0000-0000-0000-0000000000a1'$$),
  '{1,1,1,0,1,0,0,42501}', 'customers: owner, manager, lead and the plant''s display read the name; viewer, unpaired display, other tenant nothing; anon no grant');
select is(array[
  pg_temp.run_as('lead', $$update public.customers set name = 'X' where id = 'c1000000-0000-0000-0000-0000000000a1'$$),
  pg_temp.run_as('display', $$update public.customers set name = 'X' where id = 'c1000000-0000-0000-0000-0000000000a1'$$),
  pg_temp.run_as('manager', $$update public.customers set name = 'X' where id = 'c1000000-0000-0000-0000-0000000000a1'$$)],
  '{0,0,0}', 'reading does not mean writing: leads, displays and managers update nothing');

-- ══ void_customer_delivery ═══════════════════════════════════════════════
-- Line 1 (AA towels, 2 loads per bin) and line 3 (napkins) are started once each (in progress); line 2
-- (aprons) is never started. Then the delivery is voided.
select is(array[
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e8000000-0000-0000-0000-000000000001',
                    p_queue_item_id => pg_temp.qi('1', 1))$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e8000000-0000-0000-0000-000000000003', p_confirm_running => true,
                    p_queue_item_id => pg_temp.qi('1', 3), p_off_queue_reason => 'other')$$)],
  '{1,1}', 'two of the delivery''s three items are started');
select is(pg_temp.writes($$select public.void_customer_delivery(pg_temp.d('2'), 'wrong customer')$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'void_customer_delivery: owner or manager (the second call is the idempotent retry); lead, viewer, display, other tenant refused; anon cannot call');
select is(array[pg_temp.run_as('ownerB', $$select public.void_customer_delivery(gen_random_uuid(), 'x')$$),
                pg_temp.run_as('manager', $$select public.void_customer_delivery(gen_random_uuid(), 'x')$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED}', 'unknown ids: the same NOT_AUTHORIZED (no oracle)');
select is(array[pg_temp.run_as('manager', $$select public.void_customer_delivery(pg_temp.d('1'), null)$$),
                pg_temp.run_as('manager', $$select public.void_customer_delivery(pg_temp.d('1'), '   ')$$),
                pg_temp.run_as('manager', $$select public.void_customer_delivery(pg_temp.d('1'), repeat('x', 201))$$),
                pg_temp.run_as('manager', $$select public.void_customer_delivery(pg_temp.d('1'), E'bad\nreason')$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}', 'a reason is required: 1–200 characters, no control characters');
select is((select voided_at is null from public.customer_deliveries where id = pg_temp.d('1')), true, 'rejected voids changed nothing');
select is(pg_temp.val_as('manager', $$select row(cardinality(r.cancelled_item_ids), jsonb_array_length(r.kept_items),
                                                 (select string_agg(k ->> 'status' || '/' || (k ->> 'loads_started'), ',' order by k ->> 'status') from jsonb_array_elements(r.kept_items) k),
                                                 r.duplicate, r.voided_at is not null)::text
                                        from public.void_customer_delivery(pg_temp.d('1'), 'counted the bins twice') r$$),
  '(1,2,"in_progress/1,in_progress/1",f,t)',
  'a manager voids: the never-started item is cancelled; the two started ones stay (in progress) and are reported back');
select is((select array_agg(q.status::text order by l.line_no) from public.customer_delivery_lines l join public.queue_items q on q.id = l.queue_item_id
            where l.delivery_id = pg_temp.d('1')),
  '{in_progress,cancelled,in_progress}', 'queue: line 2 cancelled, lines 1 and 3 untouched');
select is((select row(voided_by = pg_temp.id('manager'), void_reason)::text from public.customer_deliveries where id = pg_temp.d('1')),
  '(t,"counted the bins twice")', 'the delivery records who voided and why');
select is(pg_temp.val_as('owner', $$select row(cardinality(r.cancelled_item_ids), jsonb_array_length(r.kept_items), r.duplicate)::text
                                      from public.void_customer_delivery(pg_temp.d('1'), 'again') r$$),
  '(0,2,t)', 'voiding again: nothing changes, duplicate = true (the first reason stands)');
select is((select void_reason from public.customer_deliveries where id = pg_temp.d('1')), 'counted the bins twice', 'the first void stands');
select is((select array_agg(q.status::text) from public.customer_delivery_lines l join public.queue_items q on q.id = l.queue_item_id
            where l.delivery_id = pg_temp.d('2')),
  '{cancelled}', 'delivery 2 (voided by the owner above): its only item was cancelled');
select is((select app.alert_payload(a) ->> 'voided' from public.alert_events a where a.kind = 'customer_delivery' and a.subject_id = pg_temp.d('1')), 'true',
  'its customer_delivery alert now says voided (send-alerts treats it as stale)');
select is((select count(*)::int from public.audit_log where entity = 'customer_deliveries' and action = 'customer_deliveries.update'), 2,
  'both voids are audited');

-- ══ DATA ═════════════════════════════════════════════════════════════════
select is((select es from (select r.label_i18n ->> 'es' es from public.machine_down_reasons r where r.plant_id = pg_temp.id('plantA') and r.code = 'soap_dispenser') x),
  'Máquina de jabón', 'the soap machine-down reason (code soap_dispenser) is "Máquina de jabón" in Spanish');
select is((select count(*)::int from public.wash_groups g join public.customers c on c.id = g.customer_id and c.plant_id = g.plant_id
             join public.plants p on p.id = g.plant_id and p.name = 'Miami' where c.name = 'AA Linen' and g.active), 12,
  'ADB (seed / data migration): AA Linen has 12 active groups');
select is((select count(distinct g.color_hex)::int from public.wash_groups g join public.plants p on p.id = g.plant_id and p.name = 'Miami'),
  (select count(*)::int from public.wash_groups g join public.plants p on p.id = g.plant_id and p.name = 'Miami'),
  'ADB: every group (ours and AA''s) has its own color');

select * from finish();
rollback;
