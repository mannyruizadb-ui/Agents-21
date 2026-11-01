-- §4.7 matrix + validation: areas, stations, machines, item_types, wash_formulas; §4.6 app.to_loads.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(40);

-- R: every plant role incl. a paired display; never another tenant or anon.
select is(pg_temp.reads($$select 1 from public.areas where plant_id = pg_temp.id('plantA')$$), '{3,3,3,3,3,0,0,0}', 'areas R');
select is(pg_temp.reads($$select 1 from public.stations where plant_id = pg_temp.id('plantA')$$), '{1,1,1,1,1,0,0,0}', 'stations R');
select is(pg_temp.reads($$select 1 from public.machines where plant_id = pg_temp.id('plantA')$$), '{1,1,1,1,1,0,0,0}', 'machines R');
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
select is(pg_temp.writes($$insert into public.item_types (org_id, plant_id, name, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'I-' || substr(md5(random()::text), 1, 8), 'other')$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'item_types C');
select is(pg_temp.writes($$insert into public.wash_formulas (org_id, plant_id, external_no)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), substr(md5(random()::text), 1, 8))$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'wash_formulas C');

-- U: owner/manager only.
select is(pg_temp.writes($$update public.areas set sort_order = 1 where plant_id = pg_temp.id('plantA')$$), '{5,5,0,0,0,0,0,0}', 'areas U');
select is(pg_temp.writes($$update public.stations set active = true where plant_id = pg_temp.id('plantA')$$), '{3,3,0,0,0,0,0,0}', 'stations U');
select is(pg_temp.writes($$update public.machines set active = true where plant_id = pg_temp.id('plantA')$$), '{3,3,0,0,0,0,0,0}', 'machines U');
select is(pg_temp.writes($$update public.item_types set sort_order = 1 where plant_id = pg_temp.id('plantA')$$), '{5,5,0,0,0,0,0,0}', 'item_types U');
select is(pg_temp.writes($$update public.wash_formulas set name = 'n' where plant_id = pg_temp.id('plantA')$$), '{3,3,0,0,0,0,0,0}', 'wash_formulas U');
select is(pg_temp.run_as('owner', $$update public.areas set plant_id = pg_temp.id('plantB'), org_id = pg_temp.id('orgB') where id = pg_temp.id('spare')$$),
  '42501', 'cannot move a row into another tenant');

-- Security M2: SECURITY DEFINER BEFORE triggers are not cross-tenant oracles. Owner B probing plant A
-- with a bad translation gets the RLS denial, not plant A's language validation result.
select is(pg_temp.run_as('ownerB', $$insert into public.item_types (org_id, plant_id, name, name_i18n, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Probe', '{"ht":"x"}', 'other')$$), '42501',
  'trigger oracle closed: other tenant gets 42501, not VALIDATION_FAILED');
select is(pg_temp.run_as('manager', $$insert into public.item_types (org_id, plant_id, name, name_i18n, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Probe', '{"ht":"x"}', 'other')$$), 'VALIDATION_FAILED',
  'members of the plant still get the validation error');

-- Tenant consistency (composite FKs).
select throws_ok($$insert into public.stations (org_id, plant_id, area_id, name, kind)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('washB'), 'Cross', 'ironer')$$, '23503', null,
  'station cannot reference another plant''s area');
select throws_ok($$insert into public.wash_formulas (org_id, plant_id, external_no, item_type_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), '99', pg_temp.id('itemB'))$$, '23503', null,
  'formula cannot reference another plant''s item');
select throws_ok($$insert into public.areas (org_id, plant_id, name, kind) values (pg_temp.id('orgB'), pg_temp.id('plantA'), 'Z', 'other')$$,
  '23503', null, 'plant must belong to the row''s org');

-- item_types CHECKs and language rules.
select throws_ok($$insert into public.item_types (org_id, plant_id, name, category, count_mode)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'P1', 'linen', 'pack')$$, '23514', null, 'pack item needs pack_size');
select throws_ok($$insert into public.item_types (org_id, plant_id, name, category, allow_basket_estimates)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'P2', 'linen', true)$$, '23514', null, 'baskets need baskets_per_load');
select throws_ok($$insert into public.item_types (org_id, plant_id, name, category, default_estimate_unit)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'P3', 'linen', 'basket')$$, '23514', null, 'basket default needs baskets allowed');
select throws_ok($$insert into public.item_types (org_id, plant_id, name, category, default_estimate_unit)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'P4', 'linen', 'piece')$$, '23514', null, 'estimate unit is load or basket');
select throws_ok($$insert into public.item_types (org_id, plant_id, name, category, pieces_per_load)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'P5', 'linen', 400)$$, '23514', null, 'pieces_per_load needs its source');
select throws_ok($$insert into public.item_types (org_id, plant_id, name, category, color_hex)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'P6', 'linen', 'red')$$, '23514', null, 'color is #RRGGBB');
select throws_ok($$insert into public.item_types (org_id, plant_id, name, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), ' Padded', 'linen')$$, '23514', null, 'names are trimmed');
select throws_ok($$insert into public.item_types (org_id, plant_id, name, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), E'Tab\there', 'linen')$$, '23514', null, 'control characters rejected');
select throws_ok($$insert into public.item_types (org_id, plant_id, name, name_i18n, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'P7', '{"ht":"Sèvyèt"}', 'linen')$$, 'P0001', 'VALIDATION_FAILED',
  'translation language must be enabled for the plant');
select throws_ok($$insert into public.item_types (org_id, plant_id, name, name_i18n, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'P8', jsonb_build_object('es', repeat('x', 61)), 'linen')$$, 'P0001', 'VALIDATION_FAILED',
  'translation values are 1–60 characters');

-- Audit (A2: every change audited with before/after).
select is(pg_temp.run_as('manager', $$update public.item_types set pack_size = 50 where id = pg_temp.id('napkin')$$), '1', 'manager edits pack size');
select is((select array[actor_user_id::text, before ->> 'pack_size', after ->> 'pack_size'] from public.audit_log
            where entity = 'item_types' and entity_id = pg_temp.id('napkin') and action = 'item_types.update'
              and after ->> 'pack_size' = '50'),
  array[pg_temp.id('manager')::text, '100', '50'], 'item_types change audited with before/after');
update public.item_types set pack_size = 100 where id = pg_temp.id('napkin');

-- §4.6 app.to_loads: one function, null when a factor is missing.
select is(app.to_loads(pg_temp.id('napkin'), 3, 'load'), 3::numeric, 'to_loads load = qty');
select is(app.to_loads(pg_temp.id('towel'), 3, 'basket'), 1.5, 'to_loads basket = qty / baskets_per_load');
select is(app.to_loads(pg_temp.id('napkin'), 1000, 'piece'), 2::numeric, 'to_loads piece = qty / pieces_per_load');
select is(app.to_loads(pg_temp.id('napkin'), 10, 'pack'), 2::numeric, 'to_loads pack = qty * pack_size / pieces_per_load');
select is(array[app.to_loads(pg_temp.id('napkin'), 3, 'basket'), app.to_loads(pg_temp.id('mat'), 10, 'piece'),
                app.to_loads(pg_temp.id('towel'), 1, 'pack'), app.to_loads(gen_random_uuid(), 1, 'load')],
  array[null, null, null, null]::numeric[], 'to_loads is null when baskets_per_load / pieces_per_load / pack_size / item is missing');
select is(pg_temp.run_as('ownerB', $$select 1 where app.to_loads(pg_temp.id('napkin'), 3, 'load') is null$$, true), '1',
  'to_loads cannot read another tenant''s item');

select * from finish();
rollback;
