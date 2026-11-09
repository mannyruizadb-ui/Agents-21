-- Wash group category (owner 2026-11-09; 20261109182651): the estimate filter chip a group falls under.
-- Column + CHECK, read matrix, write path (owner/manager on our own groups, customer groups owner-only,
-- no other role or tenant), audit, and the ADB data (ours and AA Linen's). Matrix arrays: [owner,
-- manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(16);

-- ══ Column ═══════════════════════════════════════════════════════════════
select col_not_null('public', 'wash_groups', 'category', 'category is not null');
select col_default_is('public', 'wash_groups', 'category', 'other', 'category defaults to ''other''');
select is(pg_temp.as_service($$insert into public.wash_groups (org_id, plant_id, name, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Bad category', 'rugs')$$), '23514',
  'CHECK rejects a value outside the 7 categories');
select is(array[
  pg_temp.as_service($$update public.wash_groups set category = 'Mats' where id = pg_temp.id('gMat')$$),
  pg_temp.as_service($$update public.wash_groups set category = '' where id = pg_temp.id('gMat')$$),
  pg_temp.as_service($$update public.wash_groups set category = null where id = pg_temp.id('gMat')$$)],
  '{23514,23514,23502}', 'CHECK is case-sensitive and rejects empty; null is rejected');
select is((select array_agg(c order by c) from unnest(array['napkins','tablecloths','sheets','mats','towels_aprons','mops','other']) c
            where pg_temp.as_service(format($$update public.wash_groups set category = %L where id = pg_temp.id('gTowel')$$, c)) = '1'),
  array['mats','mops','napkins','other','sheets','tablecloths','towels_aprons'], 'every one of the 7 categories is accepted');

-- ══ Read matrix: same as the rest of the row ══════════════════════════════
select is(pg_temp.reads($$select category from public.wash_groups where id = pg_temp.id('gNapkin')$$),
  '{1,1,1,1,1,0,0,42501}',
  'category: owner, manager, lead, viewer and the plant''s display read it; unpaired display and other tenant nothing; anon no grant');

-- ══ Write path ═══════════════════════════════════════════════════════════
select is(pg_temp.writes($$update public.wash_groups set category = 'napkins' where id = pg_temp.id('gNapkin')$$),
  '{1,1,0,0,0,0,0,42501}',
  'update on our own group: owner and manager; lead, viewer, displays and other tenant update nothing (RLS); anon no grant');
select is(pg_temp.run_as('ownerB', $$update public.wash_groups set category = 'mats' where id = pg_temp.id('gMat')$$), '0',
  'cross-tenant: owner of B cannot touch plant A''s group');
select is(pg_temp.run_as('owner', $$update public.wash_groups set category = 'towels' where id = pg_temp.id('gTowel')$$), '23514',
  'a client write outside the 7 values is rejected by the CHECK');
select is(pg_temp.run_as('owner', $$insert into public.wash_groups (org_id, plant_id, name, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'New linen', 'tablecloths')$$), '1',
  'the owner adds a group with its category');

insert into public.customers (id, org_id, plant_id, name) values
  ('c1000000-0000-0000-0000-0000000000c1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Category customer');
insert into public.wash_groups (id, org_id, plant_id, customer_id, name) values
  ('71000000-0000-0000-0000-0000000cc0a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000c1', 'Cust napkins');
select is(array[
  pg_temp.run_as('manager', $$update public.wash_groups set category = 'napkins' where id = '71000000-0000-0000-0000-0000000cc0a1'$$),
  pg_temp.run_as('owner',   $$update public.wash_groups set category = 'napkins' where id = '71000000-0000-0000-0000-0000000cc0a1'$$)],
  '{NOT_AUTHORIZED,1}', 'a customer''s group: the owner sets its category, a manager cannot');

select is((select array[before ->> 'category', after ->> 'category', actor_user_id::text] from public.audit_log
            where entity = 'wash_groups' and entity_id = '71000000-0000-0000-0000-0000000cc0a1' and action = 'wash_groups.update'
              and after ->> 'category' = 'napkins'),
  array['other', 'napkins', pg_temp.id('owner')::text], 'category edits are audited');

-- ══ ADB data (seed.sql = the data migration's mapping) ═══════════════════
create function pg_temp.adb_groups() returns table (name text, customer text, category text, active boolean) language sql stable as $$
  select g.name, c.name, g.category, g.active from public.wash_groups g
    join public.plants p on p.id = g.plant_id and p.name = 'Miami'
    join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
    left join public.customers c on c.id = g.customer_id;
$$;
select is((select coalesce(array_agg(name || coalesce(' (' || customer || ')', '') order by name), '{}') from pg_temp.adb_groups()
            where active and category = 'other'),
  '{}'::text[], 'every active ADB group (ours and AA Linen''s) has a category other than ''other''');
select is((select array_agg(category || ':' || n order by category) from
            (select category, count(*)::text as n from pg_temp.adb_groups() where customer is null group by category) x),
  array['mats:7', 'mops:2', 'napkins:12', 'sheets:3', 'tablecloths:3', 'towels_aprons:6'],
  'our 33 groups: 7 mats, 2 mops, 12 napkins, 3 sheets, 3 tablecloths, 6 towels & aprons');
select is((select array_agg(category || ':' || n order by category) from
            (select category, count(*)::text as n from pg_temp.adb_groups() where customer = 'AA Linen' group by category) x),
  array['mats:1', 'napkins:3', 'tablecloths:4', 'towels_aprons:4'],
  'AA Linen''s 12 groups: 1 mats, 3 napkins, 4 tablecloths, 4 towels & aprons');
select is((select array_agg(name order by name) from pg_temp.adb_groups() where customer = 'AA Linen' and category = 'towels_aprons'),
  array['Black aprons', 'Kitchen towels', 'Stained hotel towels', 'White aprons'],
  'AA towels & aprons: kitchen towels, white and black aprons, stained hotel towels');

select * from finish();
rollback;
