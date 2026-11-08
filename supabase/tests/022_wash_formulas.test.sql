-- Owner decision 2026-11-02 (A): wash formulas carry cycle_minutes; groups map to a formula
-- (wash_groups.wash_formula_id, group → formula, many groups per formula). wash_formulas.wash_group_id
-- stays for Accu-Flow resolution and is set only when a formula washes exactly one group.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(26);

-- Formulas of other plants (B = other tenant, A2 = same org) and a second plant-A formula shared by groups.
insert into public.wash_formulas (id, org_id, plant_id, external_no, name, cycle_minutes) values
  ('80000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'),  '1', 'B formula', 30),
  ('80000000-0000-0000-0000-0000000000c1', pg_temp.id('orgA'), pg_temp.id('plantA2'), '1', 'A2 formula', 30),
  ('80000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'),  '2', 'Mats & towels', 26);

-- ── wash_formulas.cycle_minutes ───────────────────────────────────────────
select col_type_is('public', 'wash_formulas', 'cycle_minutes', 'integer', 'cycle_minutes is an integer (minutes, never a weight)');
select col_is_null('public', 'wash_formulas', 'cycle_minutes', 'cycle_minutes is nullable (unknown = null, never guessed)');
select is((select cycle_minutes from public.wash_formulas where id = pg_temp.id('formula')), null::int, 'existing formulas have no cycle time yet');
select is(array[pg_temp.run_as('owner', $$update public.wash_formulas set cycle_minutes = 0 where id = pg_temp.id('formula')$$),
                pg_temp.run_as('owner', $$update public.wash_formulas set cycle_minutes = 301 where id = pg_temp.id('formula')$$),
                pg_temp.run_as('owner', $$update public.wash_formulas set cycle_minutes = -5 where id = pg_temp.id('formula')$$)],
  '{23514,23514,23514}', 'cycle_minutes outside 1–300 rejected');
select is(array[pg_temp.run_as('owner', $$update public.wash_formulas set cycle_minutes = 1 where id = pg_temp.id('formula')$$),
                pg_temp.run_as('owner', $$update public.wash_formulas set cycle_minutes = 300 where id = pg_temp.id('formula')$$),
                pg_temp.run_as('owner', $$update public.wash_formulas set cycle_minutes = null where id = pg_temp.id('formula')$$)],
  '{1,1,1}', 'cycle_minutes 1, 300 and null accepted');
select is(pg_temp.writes($$update public.wash_formulas set cycle_minutes = 88 where id = pg_temp.id('formula')$$),
  '{1,1,0,0,0,0,0,42501}', 'cycle_minutes U: owner/manager only (same matrix as wash_formulas)');
select is(pg_temp.writes($$insert into public.wash_formulas (org_id, plant_id, external_no, cycle_minutes)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'X' || substr(md5(random()::text), 1, 6), 42)$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'formula with a cycle time C: owner/manager only');
select is(pg_temp.reads($$select cycle_minutes from public.wash_formulas where id = pg_temp.id('formula')$$),
  '{1,1,1,1,1,0,0,42501}', 'cycle_minutes R: plant roles and own-plant display; no cross-tenant');
select is(pg_temp.run_as('ownerB', $$update public.wash_formulas set cycle_minutes = 5 where plant_id = pg_temp.id('plantA')$$),
  '0', 'owner of B cannot change plant A cycle times');
select ok((select count(*) >= 2 from public.audit_log where action = 'wash_formulas.update' and entity_id = pg_temp.id('formula')),
  'cycle time changes are audited');

-- ── wash_groups.wash_formula_id (group → formula) ─────────────────────────
select col_type_is('public', 'wash_groups', 'wash_formula_id', 'uuid', 'wash_groups.wash_formula_id is a uuid');
select col_is_null('public', 'wash_groups', 'wash_formula_id', 'wash_formula_id is nullable (null = unmapped)');
select has_index('public', 'wash_groups', 'wash_groups_formula_plant_idx', array['wash_formula_id', 'plant_id'],
  'wash_formula_id FK is indexed');
select is(pg_temp.writes($$update public.wash_groups set wash_formula_id = '80000000-0000-0000-0000-0000000000a2' where id = pg_temp.id('gMat')$$),
  '{1,1,0,0,0,0,0,42501}', 'wash_formula_id U: owner/manager only (lead, viewer, display, other tenant, anon cannot)');
select is(pg_temp.run_as('manager', $$update public.wash_groups set wash_formula_id = '80000000-0000-0000-0000-0000000000a2' where id = pg_temp.id('gTowel')$$),
  '1', 'a second group can use the same formula');
select is((select count(*)::int from public.wash_groups where wash_formula_id = '80000000-0000-0000-0000-0000000000a2'),
  2, 'one formula washes many groups');
select is(pg_temp.writes($$insert into public.wash_groups (org_id, plant_id, name, wash_formula_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'G ' || substr(md5(random()::text), 1, 8), '80000000-0000-0000-0000-0000000000a2')$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'group with a formula C: owner/manager only');
select is(pg_temp.reads($$select 1 from public.wash_groups where wash_formula_id = '80000000-0000-0000-0000-0000000000a2' and plant_id = pg_temp.id('plantA')$$),
  '{4,4,4,4,4,0,0,42501}', 'wash_formula_id R: plant roles and own-plant display; no cross-tenant');
select is(array[pg_temp.run_as('manager', $$update public.wash_groups set wash_formula_id = '80000000-0000-0000-0000-0000000000b1' where id = pg_temp.id('gNapkin')$$),
                pg_temp.run_as('manager', $$update public.wash_groups set wash_formula_id = '80000000-0000-0000-0000-0000000000c1' where id = pg_temp.id('gNapkin')$$)],
  '{23503,23503}', 'a group cannot use another tenant''s or another plant''s formula');
-- No oracle: owner B on their own group gets the same answer for a real plant A formula and a missing one.
select is(array[pg_temp.run_as('ownerB', $$update public.wash_groups set wash_formula_id = pg_temp.id('formula') where id = pg_temp.id('groupB')$$),
                pg_temp.run_as('ownerB', $$update public.wash_groups set wash_formula_id = gen_random_uuid() where id = pg_temp.id('groupB')$$)],
  '{23503,23503}', 'foreign formula vs missing formula → same 23503 for owner B');
select is(pg_temp.run_as('ownerB', $$update public.wash_groups set wash_formula_id = '80000000-0000-0000-0000-0000000000b1' where id = pg_temp.id('groupB')$$),
  '1', 'owner B maps their own group to their own formula');
select ok((select count(*) = 1 from public.audit_log where action = 'wash_groups.update' and entity_id = pg_temp.id('gMat') and before ->> 'wash_formula_id' is null
             and after ->> 'wash_formula_id' = '80000000-0000-0000-0000-0000000000a2'),
  'formula mapping changes are audited (a repeat of the same value is a no-op, not audited)');

-- ── Accu-Flow resolution: only a single-group formula resolves a cycle's group ──
select is((select wash_group_id from public.wash_formulas where id = '80000000-0000-0000-0000-0000000000a2'), null::uuid,
  'a formula shared by several groups keeps wash_group_id null');
insert into public.washer_cycles (id, org_id, plant_id, area_id, wash_formula_id, started_at, source, entered_by, client_id) values
  ('f1000000-0000-0000-0000-0000000000c1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'),
   '80000000-0000-0000-0000-0000000000a2', pg_temp.ny('2026-11-03 01:00'), 'manual', pg_temp.id('lead'), gen_random_uuid());
select is((select wash_group_id from public.washer_cycles where id = 'f1000000-0000-0000-0000-0000000000c1'), null::uuid,
  'a cycle with a shared formula and no group stays unmapped');
insert into public.washer_cycles (id, org_id, plant_id, area_id, wash_formula_id, started_at, source, entered_by, client_id) values
  ('f1000000-0000-0000-0000-0000000000c2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'),
   pg_temp.id('formula'), pg_temp.ny('2026-11-03 02:00'), 'manual', pg_temp.id('lead'), gen_random_uuid());
select is((select wash_group_id from public.washer_cycles where id = 'f1000000-0000-0000-0000-0000000000c2'), pg_temp.id('gNapkin'),
  'a single-group formula still resolves the cycle''s group');
select is((select array_agg(wash_group_id is null order by wash_group_id is null) from public.washroom_by_shift
            where shift_instance_id = pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03') and plant_id = pg_temp.id('plantA')),
  array[false, true], 'washroom_by_shift shows the unmapped cycle with a null group');

select * from finish();
rollback;
