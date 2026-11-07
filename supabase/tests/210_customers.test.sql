-- Outside customers (owner 2026-11-06, A): customers table (§4.7 matrix), wash_groups.customer_id (owner
-- only), customer snapshots on queue_items / washer_cycles, and the AA Linen data migration.
begin;
\ir _fixtures.psql
select plan(36);

-- Customers: AA (plant A), AA2 (plant A, a second customer), B (plant B).
insert into public.customers (id, org_id, plant_id, name, name_i18n) values
  ('c1000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'AA Test', '{"es":"AA Prueba"}'),
  ('c1000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Other Co', '{}'),
  ('c1000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), 'B Customer', '{}');
insert into public.wash_groups (id, org_id, plant_id, customer_id, name) values
  ('71000000-0000-0000-0000-0000000aa0a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1', 'Napkins');
create function pg_temp.c(p text) returns uuid language sql immutable as $$
  select (case p when 'aa' then 'c1000000-0000-0000-0000-0000000000a1'
                 when 'aa2' then 'c1000000-0000-0000-0000-0000000000a2'
                 when 'b' then 'c1000000-0000-0000-0000-0000000000b1'
                 when 'gAA' then '71000000-0000-0000-0000-0000000aa0a1' end)::uuid;
$$;
grant execute on function pg_temp.c(text) to authenticated, anon;

-- ══ customers: structure and §4.7 matrix ═════════════════════════════════
select ok((select relrowsecurity from pg_class where oid = 'public.customers'::regclass), 'customers: RLS enabled');
select is(pg_temp.reads($$select * from public.customers where plant_id = pg_temp.id('plantA')$$),
  '{2,2,0,0,0,0,0,42501}', 'customers R: owner and manager of the plant only (lead, viewer, display, other tenant: nothing; anon: no grant)');
select is(pg_temp.reads($$select * from public.customers where plant_id = pg_temp.id('plantB')$$),
  '{0,0,0,0,0,0,1,42501}', 'customers R: cross-tenant rows are invisible');
select is(pg_temp.writes($$insert into public.customers (org_id, plant_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'New Co')$$),
  '{1,42501,42501,42501,42501,42501,42501,42501}', 'customers C: owner only');
select is(pg_temp.writes($$insert into public.customers (org_id, plant_id, name) values (pg_temp.id('orgB'), pg_temp.id('plantB'), 'Sneaky')$$),
  '{42501,42501,42501,42501,42501,42501,1,42501}', 'customers C: never into another tenant');
select is(pg_temp.writes($$update public.customers set sort_order = sort_order + 1 where id = pg_temp.c('aa')$$),
  '{1,0,0,0,0,0,0,42501}', 'customers U: owner only');
select is(pg_temp.writes($$update public.customers set active = false where id = pg_temp.c('b')$$),
  '{0,0,0,0,0,0,1,42501}', 'customers U: cross-tenant rows untouched');
select is(pg_temp.writes($$delete from public.customers where id = pg_temp.c('aa2')$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'customers D: nobody (deactivate, never delete)');
select is(pg_temp.as_service($$delete from public.customers where id = pg_temp.c('aa2')$$), 'VALIDATION_FAILED',
  'customers: never deleted, even by the service role');
select is(pg_temp.run_as('owner', $$update public.customers set created_at = now() where id = pg_temp.c('aa')$$), '42501',
  'customers: created_at is not client-writable (column grants)');
select is(array[
  pg_temp.run_as('owner', $$insert into public.customers (org_id, plant_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), '')$$),
  pg_temp.run_as('owner', $$insert into public.customers (org_id, plant_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), repeat('x', 61))$$),
  pg_temp.run_as('owner', $$insert into public.customers (org_id, plant_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'AA Test')$$),
  pg_temp.run_as('owner', $$insert into public.customers (org_id, plant_id, name, name_i18n) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Lang Co', '{"ht":"X"}')$$),
  pg_temp.run_as('owner', $$insert into public.customers (org_id, plant_id, name, name_i18n) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Arr Co', '[]')$$),
  pg_temp.run_as('owner', $$insert into public.customers (org_id, plant_id, name) values (pg_temp.id('orgB'), pg_temp.id('plantA'), 'Mixed Co')$$)],
  '{23514,23514,23505,VALIDATION_FAILED,22023,23503}',
  'customers CHECKs: name 1–60, unique per plant, i18n languages enabled for the plant, i18n is an object, plant/org must match');
select is(pg_temp.run_as('owner', $$update public.customers set name_i18n = '{"es":"AA Lino"}' where id = pg_temp.c('aa')$$), '1',
  'the owner renames a customer (es)');
select is((select count(*)::int from public.audit_log where entity = 'customers' and entity_id = pg_temp.c('aa') and action = 'customers.update'), 2,
  'customer edits are audited');

-- ══ wash_groups.customer_id: owner only ══════════════════════════════════
select is(array[
  pg_temp.run_as('owner',   $$insert into public.wash_groups (org_id, plant_id, customer_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.c('aa'), 'Aprons')$$),
  pg_temp.run_as('manager', $$insert into public.wash_groups (org_id, plant_id, customer_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.c('aa'), 'Mats')$$),
  pg_temp.run_as('manager', $$insert into public.wash_groups (org_id, plant_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Manager group')$$),
  pg_temp.run_as('lead',    $$insert into public.wash_groups (org_id, plant_id, customer_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.c('aa'), 'Lead group')$$),
  pg_temp.run_as('ownerB',  $$insert into public.wash_groups (org_id, plant_id, customer_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.c('aa'), 'B group')$$)],
  '{1,NOT_AUTHORIZED,1,NOT_AUTHORIZED,42501}',
  'wash_groups C with a customer: owner only (a manager may still add our own groups; a lead is refused; another tenant: RLS)');
select is(array[
  pg_temp.run_as('manager', $$update public.wash_groups set customer_id = pg_temp.c('aa') where id = pg_temp.id('gMat')$$),
  pg_temp.run_as('manager', $$update public.wash_groups set customer_id = null where id = pg_temp.c('gAA')$$),
  pg_temp.run_as('manager', $$update public.wash_groups set sort_order = 5 where id = pg_temp.c('gAA')$$),
  pg_temp.run_as('owner',   $$update public.wash_groups set customer_id = pg_temp.c('aa2') where id = pg_temp.id('gMat')$$),
  pg_temp.run_as('owner',   $$update public.wash_groups set customer_id = null where id = pg_temp.id('gMat')$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,1,1,1}',
  'wash_groups U customer_id: owner only; a manager keeps their other edits on a customer group');
select is(pg_temp.run_as('owner', $$update public.wash_groups set customer_id = pg_temp.c('b') where id = pg_temp.id('gMat')$$), '23503',
  'composite FK: a group cannot point at another tenant''s customer');
select is(array[
  pg_temp.run_as('owner', $$insert into public.wash_groups (org_id, plant_id, customer_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.c('aa'), 'Towels')$$),
  pg_temp.run_as('owner', $$insert into public.wash_groups (org_id, plant_id, customer_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.c('aa'), 'Napkins')$$),
  pg_temp.run_as('owner', $$insert into public.wash_groups (org_id, plant_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Napkins')$$)],
  '{1,23505,23505}', 'group names are unique per (plant, customer): AA "Towels" next to ours, never twice for one owner');
select is(pg_temp.reads($$select customer_id from public.wash_groups where id = pg_temp.c('gAA')$$),
  '{1,1,1,1,1,0,0,0}', 'wash_groups.customer_id is readable wherever the group is (lead, viewer, display included; never another tenant)');

-- ══ Snapshots: queue_items / washer_cycles ═══════════════════════════════
select is(array[
  pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 2, 'load', 'e1000000-0000-0000-0000-000000000001', pg_temp.c('gAA'))$$),
  pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 2, 'load', 'e1000000-0000-0000-0000-000000000002', pg_temp.id('gNapkin'))$$)],
  '{1,1}', 'queue items for an AA group and one of ours');
select is(array(select coalesce(customer_id::text, 'ours') from public.queue_items
                 where client_id in ('e1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000002') order by client_id),
  array[pg_temp.c('aa')::text, 'ours'], 'queue_items.customer_id = the group''s customer (null = ours)');
select is(pg_temp.reads($$select customer_id from public.queue_items where client_id = 'e1000000-0000-0000-0000-000000000001'$$),
  '{1,1,1,1,1,0,0,42501}', 'queue_items.customer_id is a readable column (column grant)');
select is(pg_temp.as_service($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id, customer_id)
                               values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), 1, 'load', 999, pg_temp.id('owner'), 'e1000000-0000-0000-0000-000000000003', pg_temp.c('aa'))$$),
  '1', 'a direct insert that names a customer …');
select is((select customer_id from public.queue_items where client_id = 'e1000000-0000-0000-0000-000000000003'), null,
  '… gets the group''s customer instead (the trigger overwrites it)');
select is(pg_temp.as_service($$update public.queue_items set customer_id = null where client_id = 'e1000000-0000-0000-0000-000000000001'$$), '1',
  'an update that tries to change the snapshot …');
select is((select customer_id from public.queue_items where client_id = 'e1000000-0000-0000-0000-000000000001'), pg_temp.c('aa'),
  '… leaves it unchanged');

select is(array[
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e2000000-0000-0000-0000-000000000001', p_wash_group_id => pg_temp.c('gAA'))$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e2000000-0000-0000-0000-000000000002', p_wash_group_id => pg_temp.id('gMat'), p_confirm_running => true)$$)],
  '{1,1}', 'start_washer_load (unchanged signature): an AA load from the queue and an off-queue load of ours');
select is(array(select coalesce(customer_id::text, 'ours') from public.washer_cycles
                 where client_id in ('e2000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002') order by client_id),
  array[pg_temp.c('aa')::text, 'ours'], 'washer_cycles.customer_id = the group''s customer at the start');
select is((select q.customer_id from public.washer_cycles w join public.queue_items q on q.id = w.queue_item_id
            where w.client_id = 'e2000000-0000-0000-0000-000000000001'), pg_temp.c('aa'), 'the AA load came from the AA queue item');
update public.wash_groups set customer_id = pg_temp.c('aa2') where id = pg_temp.c('gAA');
select is((select customer_id from public.washer_cycles where client_id = 'e2000000-0000-0000-0000-000000000001'), pg_temp.c('aa'),
  'a snapshot: moving the group to another customer later does not rewrite history');
select is(pg_temp.reads($$select customer_id from public.washer_cycles where client_id = 'e2000000-0000-0000-0000-000000000001'$$),
  pg_temp.reads($$select id from public.washer_cycles where client_id = 'e2000000-0000-0000-0000-000000000001'$$),
  'washer_cycles.customer_id is readable exactly where the cycle is (existing washer_cycles rules; column grant)');

-- ══ ADB data migration: AA Linen ═════════════════════════════════════════
create function pg_temp.aa_groups() returns setof public.wash_groups language sql stable as $$
  select g.* from public.wash_groups g
    join public.customers c on c.id = g.customer_id and c.plant_id = g.plant_id and c.name = 'AA Linen'
    join public.plants p on p.id = g.plant_id and p.name = 'Miami'
    join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters';
$$;
select is((select array_agg(name || '=' || (name_i18n ->> 'es') order by sort_order) from pg_temp.aa_groups()),
  array['Kitchen towels=Toallas de cocina', 'Aprons=Delantales', 'Mats=Mapos', 'Napkins=Servilletas', 'Tablecloths=Manteles',
        'Stained white napkins=Servilletas blancas manchadas', 'Stained white tablecloths=Manteles blancos manchados',
        'Stained hotel towels=Toallas de hotel manchadas'],
  'ADB: AA Linen has its own 8 wash groups (EN + ES)');
select is((select array_agg(name || '=' || coalesce(loads_per_bin::text, 'null') || '/' || allow_bin_estimates order by sort_order)
             from pg_temp.aa_groups() where loads_per_bin is not null or allow_bin_estimates), array['Mats=4.000/true'],
  'only AA Mats have a bin factor (4 loads per full bin); the others wait for the owner (null, never guessed)');
select is((select count(*)::int from pg_temp.aa_groups() where wash_formula_id is null and active), 8,
  'no formula is invented: the owner picks one per AA group');
-- Re-run the migration's data statements: nothing changes.
select is(pg_temp.as_service($$
insert into public.customers (org_id, plant_id, name, name_i18n, sort_order)
select p.org_id, p.id, 'AA Linen', '{}'::jsonb, 10
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami'
on conflict (plant_id, name) do nothing$$), '0', 'data migration re-run: AA Linen is not added twice');
select is(pg_temp.as_service($$
insert into public.wash_groups (org_id, plant_id, customer_id, name, name_i18n, color_hex, sort_order, loads_per_bin, allow_bin_estimates)
select c.org_id, c.plant_id, c.id, v.name, pg_catalog.jsonb_build_object('es', v.es), v.color, v.sort_order, v.per_bin, v.per_bin is not null
  from public.customers c
  join public.plants p on p.id = c.plant_id and p.name = 'Miami'
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
   ('Kitchen towels', 'Toallas de cocina', '#C2410C', 1000, null::numeric),
   ('Mats', 'Mapos', '#A16207', 1020, 4)) as v(name, es, color, sort_order, per_bin)
 where c.name = 'AA Linen'
   and not exists (select 1 from public.wash_groups g where g.plant_id = c.plant_id and g.customer_id = c.id and g.name = v.name)$$),
  '0', 'data migration re-run: no AA group is added twice');
select is((select count(*)::int from public.customers c join public.plants p on p.id = c.plant_id and p.name = 'Miami'), 1,
  'ADB: exactly one customer (AA Linen)');

select * from finish();
rollback;
