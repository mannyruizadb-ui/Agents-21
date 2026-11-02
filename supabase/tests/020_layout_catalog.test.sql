-- §4.7 matrix + validation: areas, stations, machines, wash_groups, item_types, wash_formulas; §4.6 app.to_loads.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(55);

-- R: every plant role incl. a paired display; never another tenant or anon.
select is(pg_temp.reads($$select 1 from public.areas where plant_id = pg_temp.id('plantA')$$), '{3,3,3,3,3,0,0,0}', 'areas R');
select is(pg_temp.reads($$select 1 from public.stations where plant_id = pg_temp.id('plantA')$$), '{1,1,1,1,1,0,0,0}', 'stations R');
select is(pg_temp.reads($$select 1 from public.machines where plant_id = pg_temp.id('plantA')$$), '{1,1,1,1,1,0,0,0}', 'machines R');
select is(pg_temp.reads($$select 1 from public.wash_groups where plant_id = pg_temp.id('plantA')$$), '{3,3,3,3,3,0,0,0}', 'wash_groups R');
select is(pg_temp.reads($$select 1 from public.item_types where plant_id = pg_temp.id('plantA')$$), '{3,3,3,3,3,0,0,0}', 'item_types R');
select is(pg_temp.reads($$select 1 from public.wash_formulas where plant_id = pg_temp.id('plantA')$$), '{1,1,1,1,1,0,0,0}', 'wash_formulas R');
select is(pg_temp.run_as('ownerB', $$select 1 from public.areas$$, true), '1', 'owner B sees only tenant B areas');

-- C: owner/manager only (owner B cannot write into tenant A).
select is(pg_temp.writes($$insert into public.areas (org_id, plant_id, name, kind)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'A-' || substr(md5(random()::text), 1, 8), 'other')$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'areas C');
select is(pg_temp.writes($$insert into public.stations (org_id, plant_id, area_id, name, kind)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), 'S-' || substr(md5(random()::text), 1, 8), 'folder')$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'stations C');
select is(pg_temp.writes($$insert into public.machines (org_id, plant_id, area_id, name, kind)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'M-' || substr(md5(random()::text), 1, 8), 'dryer')$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'machines C');
select is(pg_temp.writes($$insert into public.wash_groups (org_id, plant_id, name)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'G-' || substr(md5(random()::text), 1, 8))$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'wash_groups C');
select is(pg_temp.writes($$insert into public.item_types (org_id, plant_id, wash_group_id, name, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'), 'I-' || substr(md5(random()::text), 1, 8), 'other')$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'item_types C');
select is(pg_temp.writes($$insert into public.wash_formulas (org_id, plant_id, external_no)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), substr(md5(random()::text), 1, 8))$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'wash_formulas C');

-- U: owner/manager only.
select is(pg_temp.writes($$update public.areas set sort_order = 1 where plant_id = pg_temp.id('plantA')$$), '{5,5,0,0,0,0,0,0}', 'areas U');
select is(pg_temp.writes($$update public.stations set active = true where plant_id = pg_temp.id('plantA')$$), '{3,3,0,0,0,0,0,0}', 'stations U');
select is(pg_temp.writes($$update public.machines set active = true where plant_id = pg_temp.id('plantA')$$), '{3,3,0,0,0,0,0,0}', 'machines U');
select is(pg_temp.writes($$update public.wash_groups set sort_order = 1 where plant_id = pg_temp.id('plantA')$$), '{5,5,0,0,0,0,0,0}', 'wash_groups U');
select is(pg_temp.writes($$update public.item_types set sort_order = 1 where plant_id = pg_temp.id('plantA')$$), '{5,5,0,0,0,0,0,0}', 'item_types U');
select is(pg_temp.writes($$delete from public.wash_groups where plant_id = pg_temp.id('plantA')$$), '{0,0,0,0,0,0,0,0}',
  'wash_groups: no DELETE policy for any role (deactivate instead)');
select is(pg_temp.run_as('ownerB', $$update public.wash_groups set name = 'x' where id = pg_temp.id('gMat')$$), '0',
  'other tenant cannot update a wash group');
select is(pg_temp.writes($$update public.wash_formulas set name = 'n' where plant_id = pg_temp.id('plantA')$$), '{3,3,0,0,0,0,0,0}', 'wash_formulas U');
select is(pg_temp.run_as('owner', $$update public.areas set plant_id = pg_temp.id('plantB'), org_id = pg_temp.id('orgB') where id = pg_temp.id('spare')$$),
  '42501', 'cannot move a row into another tenant');

-- Security M2: SECURITY DEFINER BEFORE triggers are not cross-tenant oracles. Owner B probing plant A
-- with a bad translation gets the RLS denial, not plant A's language validation result.
select is(pg_temp.run_as('ownerB', $$insert into public.item_types (org_id, plant_id, wash_group_id, name, name_i18n, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'), 'Probe', '{"ht":"x"}', 'other')$$), '42501',
  'trigger oracle closed: other tenant gets 42501, not VALIDATION_FAILED');
select is(pg_temp.run_as('manager', $$insert into public.item_types (org_id, plant_id, wash_group_id, name, name_i18n, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'), 'Probe', '{"ht":"x"}', 'other')$$), 'VALIDATION_FAILED',
  'members of the plant still get the validation error');

-- Tenant consistency (composite FKs).
select throws_ok($$insert into public.stations (org_id, plant_id, area_id, name, kind)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('washB'), 'Cross', 'ironer')$$, '23503', null,
  'station cannot reference another plant''s area');
select throws_ok($$insert into public.wash_formulas (org_id, plant_id, external_no, wash_group_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), '99', pg_temp.id('groupB'))$$, '23503', null,
  'formula cannot reference another plant''s wash group');
select throws_ok($$insert into public.item_types (org_id, plant_id, wash_group_id, name, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('groupB'), 'Cross', 'mat')$$, '23503', null,
  'item must reference a wash group of its own plant (other tenant)');
select throws_ok($$insert into public.item_types (org_id, plant_id, wash_group_id, name, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('groupA2'), 'Cross', 'mat')$$, '23503', null,
  'item must reference a wash group of its own plant (same org, other plant)');
select throws_ok($$insert into public.item_types (org_id, plant_id, name, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'No group', 'mat')$$, '23502', null,
  'every item belongs to a wash group');
select throws_ok($$insert into public.areas (org_id, plant_id, name, kind) values (pg_temp.id('orgB'), pg_temp.id('plantA'), 'Z', 'other')$$,
  '23503', null, 'plant must belong to the row''s org');

-- item_types CHECKs and language rules.
select throws_ok($$insert into public.item_types (org_id, plant_id, wash_group_id, name, category, count_mode)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'), 'P1', 'linen', 'pack')$$, '23514', null, 'pack item needs pack_size');
select throws_ok($$insert into public.wash_groups (org_id, plant_id, name, allow_basket_estimates)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'G2', true)$$, '23514', null, 'baskets need baskets_per_load (wash group)');
select throws_ok($$insert into public.wash_groups (org_id, plant_id, name, default_estimate_unit)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'G3', 'basket')$$, '23514', null, 'basket default needs baskets allowed (wash group)');
select throws_ok($$insert into public.wash_groups (org_id, plant_id, name, default_estimate_unit)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'G4', 'piece')$$, '23514', null, 'group estimate unit is load or basket');
select throws_ok($$insert into public.wash_groups (org_id, plant_id, name, baskets_per_load)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'G5', 0)$$, '23514', null, 'baskets_per_load > 0');
select throws_ok($$insert into public.wash_groups (org_id, plant_id, name)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Mats')$$, '23505', null, 'wash group names are unique per plant');
select throws_ok($$insert into public.wash_groups (org_id, plant_id, name, name_i18n)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'G6', '{"ht":"Tapi"}')$$, 'P0001', 'VALIDATION_FAILED',
  'wash group translation language must be enabled for the plant');
select ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'item_types'
                       and column_name in ('baskets_per_load', 'allow_basket_estimates', 'default_estimate_unit')),
  'estimate settings live on wash_groups, not item_types');
select throws_ok($$insert into public.item_types (org_id, plant_id, wash_group_id, name, category, pieces_per_load)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'), 'P5', 'linen', 400)$$, '23514', null, 'pieces_per_load needs its source');
select throws_ok($$insert into public.item_types (org_id, plant_id, wash_group_id, name, category, color_hex)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'), 'P6', 'linen', 'red')$$, '23514', null, 'color is #RRGGBB');
select throws_ok($$insert into public.item_types (org_id, plant_id, wash_group_id, name, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'), ' Padded', 'linen')$$, '23514', null, 'names are trimmed');
select throws_ok($$insert into public.item_types (org_id, plant_id, wash_group_id, name, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'), E'Tab\there', 'linen')$$, '23514', null, 'control characters rejected');
select throws_ok($$insert into public.item_types (org_id, plant_id, wash_group_id, name, name_i18n, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'), 'P7', '{"ht":"Sèvyèt"}', 'linen')$$, 'P0001', 'VALIDATION_FAILED',
  'translation language must be enabled for the plant');
select throws_ok($$insert into public.item_types (org_id, plant_id, wash_group_id, name, name_i18n, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'), 'P8', jsonb_build_object('es', repeat('x', 61)), 'linen')$$, 'P0001', 'VALIDATION_FAILED',
  'translation values are 1–60 characters');

-- Audit (A2: every change audited with before/after).
select is(pg_temp.run_as('manager', $$update public.item_types set pack_size = 50 where id = pg_temp.id('napkin')$$), '1', 'manager edits pack size');
select is((select array[actor_user_id::text, before ->> 'pack_size', after ->> 'pack_size'] from public.audit_log
            where entity = 'item_types' and entity_id = pg_temp.id('napkin') and action = 'item_types.update'
              and after ->> 'pack_size' = '50'),
  array[pg_temp.id('manager')::text, '100', '50'], 'item_types change audited with before/after');
update public.item_types set pack_size = 100 where id = pg_temp.id('napkin');
select is(pg_temp.run_as('manager', $$update public.wash_groups set baskets_per_load = 3 where id = pg_temp.id('gTowel')$$), '1', 'manager edits baskets per load');
select is((select array[actor_user_id::text, before ->> 'baskets_per_load', after ->> 'baskets_per_load'] from public.audit_log
            where entity = 'wash_groups' and entity_id = pg_temp.id('gTowel') and action = 'wash_groups.update'
              and after ->> 'baskets_per_load' is distinct from before ->> 'baskets_per_load'),
  array[pg_temp.id('manager')::text, '2.000', '3.000'], 'wash_groups change audited with before/after');
update public.wash_groups set baskets_per_load = 2 where id = pg_temp.id('gTowel');

-- §4.6 app.to_loads(group, item, qty, unit): one function; estimates via the group, pieces via the item.
select is(app.to_loads(pg_temp.id('gNapkin'), null, 3, 'load'), 3::numeric, 'to_loads load = qty');
select is(app.to_loads(pg_temp.id('gTowel'), null, 3, 'basket'), 1.5, 'to_loads basket = qty / group baskets_per_load');
select is(app.to_loads(null, pg_temp.id('napkin'), 1000, 'piece'), 2::numeric, 'to_loads piece = qty / item pieces_per_load');
select is(app.to_loads(pg_temp.id('gNapkin'), pg_temp.id('napkin'), 10, 'pack'), 2::numeric, 'to_loads pack = qty * pack_size / pieces_per_load');
select is(array[app.to_loads(pg_temp.id('gNapkin'), null, 3, 'basket'), app.to_loads(null, pg_temp.id('mat'), 10, 'piece'),
                app.to_loads(null, pg_temp.id('towel'), 1, 'pack'), app.to_loads(gen_random_uuid(), null, 1, 'load'),
                app.to_loads(pg_temp.id('gNapkin'), null, 10, 'piece')],
  array[null, null, null, null, null]::numeric[],
  'to_loads is null when baskets_per_load / pieces_per_load / pack_size / group / item is missing');
select is(app.to_loads(pg_temp.id('gMat'), pg_temp.id('napkin'), 1000, 'piece'), null::numeric, 'to_loads is null when the item is not in the group');
select is(pg_temp.run_as('ownerB', $$select 1 where app.to_loads(pg_temp.id('gNapkin'), null, 3, 'load') is null
                                        and app.to_loads(null, pg_temp.id('napkin'), 1000, 'piece') is null$$, true), '1',
  'to_loads cannot read another tenant''s group or item');

select * from finish();
rollback;
