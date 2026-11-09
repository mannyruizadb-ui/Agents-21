-- Setup → Wash groups and Setup → Formulas in the app (owner 2026-11-09; 20261109215626_extend_wash_setup_edits):
-- direct table writes by role (OWNER-ONLY since the owner decision of 2026-11-09: managers read, never write,
-- even with can_edit_load_factors), every editable column, customer groups owner-only, CHECK / language rejections, the new load-factor ceiling (20), wash_formulas.active and
-- its link guard, and cross-tenant denial.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(40);

insert into public.customers (id, org_id, plant_id, name) values
  ('c1000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'AA Test');

-- ══ wash_groups: INSERT ══════════════════════════════════════════════════
select is(pg_temp.writes($$insert into public.wash_groups (org_id, plant_id, name, category)
                           values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'New ' || gen_random_uuid(), 'sheets')$$),
  '{1,42501,42501,42501,42501,42501,42501,42501}',
  'a new own group: owner only (2026-11-09); manager, lead, viewer, displays, another tenant and anon refused');
select is(pg_temp.run_as('owner', $$insert into public.wash_groups (org_id, plant_id, name, name_i18n, color_hex, category, wash_formula_id,
                                      loads_per_basket, loads_per_bin, allow_basket_estimates, allow_bin_estimates, default_estimate_unit, sort_order)
                                    values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Bar towels', '{"es":"Toallas de bar"}', '#AA3300', 'towels_aprons',
                                      pg_temp.id('formula'), 2.5, 3, true, true, 'bin', 500)$$), '1',
  'the owner adds a group with every setup column, factors included');
select is(pg_temp.run_as('manager', $$insert into public.wash_groups (org_id, plant_id, name, loads_per_bin, allow_bin_estimates)
                                      values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Mgr bins', 2, true)$$), 'NOT_AUTHORIZED',
  'a manager cannot add a group WITH factors (the factor guard answers first)');
select is(array[
  pg_temp.run_as('owner', $$insert into public.wash_groups (org_id, plant_id, customer_id, name, category, loads_per_bin, allow_bin_estimates)
                            values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1', 'AA Sheets', 'sheets', 1.5, true)$$),
  pg_temp.run_as('manager', $$insert into public.wash_groups (org_id, plant_id, customer_id, name)
                              values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1', 'AA Mgr')$$)],
  '{1,NOT_AUTHORIZED}', 'a customer (AA) group: the owner adds it; a manager cannot');
select is(pg_temp.run_as('ownerB', $$insert into public.wash_groups (org_id, plant_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Sneaky')$$),
  '42501', 'another tenant''s owner cannot add a group to plant A');
select is(pg_temp.run_as('owner', $$insert into public.wash_groups (org_id, plant_id, name) values (pg_temp.id('orgB'), pg_temp.id('plantA'), 'Wrong org')$$),
  '23503', 'org/plant mismatch is refused (the composite (plant_id, org_id) FK)');

-- ══ wash_groups: UPDATE, every editable column ═══════════════════════════
select is(pg_temp.run_as('owner', $$update public.wash_groups set name = 'Napkins (all)', name_i18n = '{"es":"Servilletas (todas)"}', color_hex = '#123456',
                                      category = 'napkins', wash_formula_id = pg_temp.id('formula'), loads_per_basket = 1.25, loads_per_bin = 2.75,
                                      allow_basket_estimates = true, allow_bin_estimates = true, default_estimate_unit = 'basket',
                                      sort_order = 7, active = true, ships_next_morning = true
                                    where id = pg_temp.id('gNapkin')$$), '1',
  'the owner edits every setup column of a group in one write');
select is((select array[name, name_i18n ->> 'es', color_hex, category, loads_per_basket::text, loads_per_bin::text, default_estimate_unit::text, sort_order::text]
             from public.wash_groups where id = pg_temp.id('gNapkin')),
  array['Napkins (all)', 'Servilletas (todas)', '#123456', 'napkins', '1.250', '2.750', 'basket', '7'], '… and it is stored');
select is(pg_temp.writes($$update public.wash_groups set sort_order = sort_order + 1 where id = pg_temp.id('gMat')$$),
  '{1,0,0,0,0,0,0,42501}',
  'our group''s setup columns: owner only (2026-11-09); manager, lead, viewer, displays and another tenant change nothing');
select is(array[
  pg_temp.run_as('manager', $$update public.wash_groups set name = 'Mats (all)', color_hex = '#000000', category = 'mats', active = true where id = pg_temp.id('gMat')$$),
  pg_temp.run_as('manager', $$update public.wash_groups set loads_per_bin = 3 where id = pg_temp.id('gMat')$$)],
  '{0,0}', 'a manager edits no name, colour, category, active or load factor (no rows)');
select is(pg_temp.run_as('manager', $$update public.wash_groups set sort_order = 1 where customer_id is not null$$),
  '0', 'a manager cannot edit a customer group (no rows)');
update public.memberships set can_edit_load_factors = true where user_id = pg_temp.id('manager');
select is(array[
  pg_temp.run_as('manager', $$update public.wash_groups set loads_per_bin = 3 where id = pg_temp.id('gMat')$$),
  pg_temp.run_as('manager', $$insert into public.wash_groups (org_id, plant_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Granted mgr')$$)],
  '{0,42501}', 'a manager WITH can_edit_load_factors still writes nothing on wash_groups (the grant is moot)');
update public.memberships set can_edit_load_factors = false where user_id = pg_temp.id('manager');
select is(array[pg_temp.reads($$select 1 from public.wash_groups where id = pg_temp.id('gMat')$$)::text,
                pg_temp.reads($$select 1 from public.wash_formulas where id = pg_temp.id('formula')$$)::text],
  array['{1,1,1,1,1,0,0,42501}', '{1,1,1,1,1,0,0,42501}'],
  'reads unchanged: owner, manager, lead, viewer and the plant''s display read groups and formulas; no cross-tenant');
select is(array[
  pg_temp.run_as('owner', $$update public.wash_groups set plant_id = pg_temp.id('plantA2') where id = pg_temp.id('gMat')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set org_id = pg_temp.id('orgB') where id = pg_temp.id('gMat')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set id = gen_random_uuid() where id = pg_temp.id('gMat')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set baskets_per_load = 2 where id = pg_temp.id('gMat')$$)],
  '{42501,42501,42501,42501}', 'ids, tenancy and the deprecated baskets_per_load are not client-editable');
select is(pg_temp.run_as('owner', $$delete from public.wash_groups where id = pg_temp.id('gMat')$$), '0',
  'no deletes (no policy): deactivate instead');

-- ══ wash_groups: validation ══════════════════════════════════════════════
select is(array[
  pg_temp.run_as('owner', $$update public.wash_groups set loads_per_basket = 0 where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set loads_per_basket = 20.001 where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set loads_per_bin = 21 where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set loads_per_bin = -1 where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set loads_per_basket = 20, loads_per_bin = 0.001 where id = pg_temp.id('gTowel')$$)],
  '{23514,23514,23514,23514,1}', 'load factors: > 0 and at most 20 loads per basket / bin (20 and 0.001 pass)');
select is(array[
  pg_temp.run_as('owner', $$update public.wash_groups set color_hex = 'red' where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set category = 'linen' where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set name = '' where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set name = repeat('x', 61) where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set default_estimate_unit = 'bin', allow_bin_estimates = false where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set allow_bin_estimates = true, loads_per_bin = null where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set default_estimate_unit = 'piece' where id = pg_temp.id('gTowel')$$)],
  '{23514,23514,23514,23514,23514,23514,23514}',
  'colour must be #RRGGBB; category from the list; name 1–60; default unit must be allowed; bins need a bin factor; units load/basket/bin only');
select is(array[
  pg_temp.run_as('owner', $$update public.wash_groups set name_i18n = '{"fr":"Serviettes"}' where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set name_i18n = '{"es":""}' where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set name_i18n = '["Toallas"]' where id = pg_temp.id('gTowel')$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,22023}', 'name_i18n: enabled languages only, 1–60 characters, an object (a non-object fails in the language check, 22023)');
select is(pg_temp.run_as('owner', $$insert into public.wash_groups (org_id, plant_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Towels')$$),
  '23505', 'a second own group with the same name is refused');
insert into public.wash_formulas (id, org_id, plant_id, external_no) values
  ('80000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), '1');
select is(pg_temp.run_as('owner', $$update public.wash_groups set wash_formula_id = '80000000-0000-0000-0000-0000000000b1' where id = pg_temp.id('gTowel')$$),
  '23503', 'a group cannot point at another tenant''s formula (composite FK)');

-- ══ wash_formulas ════════════════════════════════════════════════════════
select is(pg_temp.writes($$insert into public.wash_formulas (org_id, plant_id, external_no, name, cycle_minutes)
                           values (pg_temp.id('orgA'), pg_temp.id('plantA'), left(gen_random_uuid()::text, 8), 'New program', 45)$$),
  '{1,42501,42501,42501,42501,42501,42501,42501}',
  'a new formula: owner only (2026-11-09); manager, lead, viewer, displays, another tenant and anon refused');
select is(pg_temp.run_as('owner', $$update public.wash_formulas set name = 'Napkins hot', external_no = '13', cycle_minutes = 61 where id = pg_temp.id('formula')$$),
  '1', 'the owner edits a formula''s number, name and minutes');
select is((select external_no || '/' || name || '/' || cycle_minutes || '/' || active from public.wash_formulas where id = pg_temp.id('formula')),
  '13/Napkins hot/61/true', '… stored (active by default)');
select is(pg_temp.writes($$update public.wash_formulas set cycle_minutes = 60 where id = pg_temp.id('formula')$$),
  '{1,0,0,0,0,0,0,42501}', 'formula edits: owner only (2026-11-09); everyone else changes nothing');
select is(array[
  pg_temp.run_as('owner', $$update public.wash_formulas set cycle_minutes = 0 where id = pg_temp.id('formula')$$),
  pg_temp.run_as('owner', $$update public.wash_formulas set cycle_minutes = 301 where id = pg_temp.id('formula')$$),
  pg_temp.run_as('owner', $$update public.wash_formulas set external_no = '' where id = pg_temp.id('formula')$$),
  pg_temp.run_as('owner', $$update public.wash_formulas set external_no = repeat('9', 21) where id = pg_temp.id('formula')$$),
  pg_temp.run_as('owner', $$update public.wash_formulas set name = repeat('n', 81) where id = pg_temp.id('formula')$$),
  pg_temp.run_as('owner', $$insert into public.wash_formulas (org_id, plant_id, external_no) values (pg_temp.id('orgA'), pg_temp.id('plantA'), '13')$$)],
  '{23514,23514,23514,23514,23514,23505}', 'minutes 1–300, number 1–20 characters, name ≤ 80; one formula per number per plant');
select is(array[
  pg_temp.run_as('owner', $$update public.wash_formulas set name = '' where id = pg_temp.id('formula')$$),
  pg_temp.run_as('owner', $$update public.wash_formulas set name = null, cycle_minutes = null where id = pg_temp.id('formula')$$),
  pg_temp.run_as('owner', $$update public.wash_formulas set name = 'Napkins hot', cycle_minutes = 61 where id = pg_temp.id('formula')$$)],
  '{23514,1,1}', 'a blank formula name is null, not an empty string; name and minutes may be unknown (null)');
select is(array[
  pg_temp.run_as('owner', $$update public.wash_groups set sort_order = 100001 where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set sort_order = -100001 where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set sort_order = 100000 where id = pg_temp.id('gTowel')$$)],
  '{23514,23514,1}', 'group order: within ±100000');
select is(array[
  pg_temp.run_as('owner', $$update public.wash_formulas set plant_id = pg_temp.id('plantA2') where id = pg_temp.id('formula')$$),
  pg_temp.run_as('owner', $$update public.wash_formulas set id = gen_random_uuid() where id = pg_temp.id('formula')$$),
  pg_temp.run_as('owner', $$delete from public.wash_formulas where id = pg_temp.id('formula')$$)],
  '{42501,42501,0}', 'formula ids and tenancy are fixed; no deletes');

-- ══ wash_formulas.active and the link guard ══════════════════════════════
-- gNapkin (active) uses the fixture formula since the edit above.
select is(pg_temp.run_as('owner', $$update public.wash_formulas set active = false where id = pg_temp.id('formula')$$),
  'VALIDATION_FAILED', 'a formula an active group uses cannot be retired');
select is(pg_temp.run_as('owner', $$update public.wash_groups set wash_formula_id = null where wash_formula_id = pg_temp.id('formula')$$)::int > 0,
  true, 'move its groups off it …');
select is(array[pg_temp.run_as('manager', $$update public.wash_formulas set active = false where id = pg_temp.id('formula')$$),
                pg_temp.run_as('owner', $$update public.wash_formulas set active = false where id = pg_temp.id('formula')$$)],
  '{0,1}', '… then the owner can retire it (a manager cannot: no rows)');
select is(array[
  pg_temp.run_as('owner', $$update public.wash_groups set wash_formula_id = pg_temp.id('formula') where id = pg_temp.id('gMat')$$),
  pg_temp.run_as('owner', $$insert into public.wash_groups (org_id, plant_id, name, wash_formula_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Late', pg_temp.id('formula'))$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED}', 'an active group cannot be pointed at a retired formula (update or insert)');
select is(array[
  pg_temp.run_as('owner', $$insert into public.wash_groups (org_id, plant_id, name, wash_formula_id, active) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Parked', pg_temp.id('formula'), false)$$),
  pg_temp.run_as('owner', $$update public.wash_groups set sort_order = 3 where name = 'Parked'$$),
  pg_temp.run_as('owner', $$update public.wash_groups set active = true where name = 'Parked'$$)],
  '{1,1,VALIDATION_FAILED}', 'an inactive group may keep a retired formula and be edited, but not re-activated on it');
select is(array[
  pg_temp.run_as('owner', $$update public.wash_formulas set active = true where id = pg_temp.id('formula')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set active = true where name = 'Parked'$$)],
  '{1,1}', 'bring the formula back, then the group');
select is(pg_temp.run_as('lead', $$update public.wash_formulas set active = false where id = pg_temp.id('formula')$$),
  '0', 'a lead cannot retire a formula (RLS: no rows)');
select is(pg_temp.run_as('ownerB', $$update public.wash_formulas set active = false where id = pg_temp.id('formula')$$),
  '0', 'nor can another tenant''s owner (no error that reveals the row)');
select is(pg_temp.as_service($$update public.wash_formulas set active = false where id = pg_temp.id('formula')$$),
  'VALIDATION_FAILED', 'the service role is validated too');

-- ══ Audit ════════════════════════════════════════════════════════════════
select is((select count(*)::int from public.audit_log a where a.entity = 'wash_formulas' and a.entity_id = pg_temp.id('formula')
             and a.action = 'wash_formulas.update' and a.actor_user_id = pg_temp.id('owner')) >= 2, true,
  'formula edits are audited with the editor');
select is((select count(*)::int from public.audit_log a where a.entity = 'wash_groups' and a.action = 'wash_groups.insert'
             and (a.after ->> 'name') = 'Bar towels' and a.actor_user_id = pg_temp.id('owner')), 1,
  'a new group is audited with the editor');
select is(array[has_function_privilege('authenticated', 'app.guard_wash_formula_link()', 'execute'),
                has_column_privilege('authenticated', 'public.wash_formulas', 'active', 'update'),
                has_column_privilege('authenticated', 'public.wash_groups', 'loads_per_bin', 'update')],
  array[false, true, true], 'the guard is internal; active and the factors are client-editable columns');

select * from finish();
rollback;
