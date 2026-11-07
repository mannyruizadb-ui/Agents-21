-- Bins and baskets (owner 2026-11-04, round 3): the 'bin' unit, wash_groups.loads_per_basket /
-- loads_per_bin / allow_bin_estimates, app.to_loads, estimate guards, the deprecated baskets_per_load,
-- and the ADB seed values + preset chip colors (seed.sql and the data migration
-- 20261104163718_set_wash_group_factors_and_colors.sql).
begin;
\ir _fixtures.psql
select plan(28);

-- ══ Schema and CHECKs ════════════════════════════════════════════════════
select has_column('public', 'wash_groups', 'loads_per_basket', 'wash_groups.loads_per_basket');
select has_column('public', 'wash_groups', 'loads_per_bin', 'wash_groups.loads_per_bin');
select has_column('public', 'wash_groups', 'allow_bin_estimates', 'wash_groups.allow_bin_estimates');
select is(array[
  pg_temp.as_service($$insert into public.wash_groups (org_id, plant_id, name, allow_bin_estimates) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'B1', true)$$),
  pg_temp.as_service($$insert into public.wash_groups (org_id, plant_id, name, allow_basket_estimates) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'B2', true)$$),
  pg_temp.as_service($$insert into public.wash_groups (org_id, plant_id, name, loads_per_bin) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'B3', 0)$$),
  pg_temp.as_service($$insert into public.wash_groups (org_id, plant_id, name, loads_per_basket) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'B4', -1)$$),
  pg_temp.as_service($$insert into public.wash_groups (org_id, plant_id, name, loads_per_bin) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'B5', 1000.001)$$),
  pg_temp.as_service($$insert into public.wash_groups (org_id, plant_id, name, loads_per_bin, default_estimate_unit) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'B6', 2, 'bin')$$),
  pg_temp.as_service($$insert into public.wash_groups (org_id, plant_id, name, default_estimate_unit) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'B7', 'pack')$$)],
  array['23514','23514','23514','23514','23514','23514','23514'],
  'CHECKs: bins / baskets allowed only with their factor; factors > 0 and ≤ 1000; default bin needs bins allowed; estimate unit load|basket|bin');
select is(pg_temp.as_service($$insert into public.wash_groups (org_id, plant_id, name, loads_per_bin, allow_bin_estimates, default_estimate_unit) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'B8', 2.5, true, 'bin')$$),
  '1', 'a group estimated in bins by default (2.5 loads per bin)');

-- ══ app.to_loads: the one conversion ═════════════════════════════════════
update public.wash_groups set loads_per_bin = 2.5, allow_bin_estimates = true where id = pg_temp.id('gTowel');
select is(app.to_loads(pg_temp.id('gTowel'), null, 2.5, 'bin'), 6.25, 'bin = qty × loads_per_bin (2½ bins × 2.5)');
select is(app.to_loads(pg_temp.id('gTowel'), null, 3, 'basket'), 1.5, 'basket = qty × loads_per_basket (3 × 0.5)');
select is(array[app.to_loads(pg_temp.id('gNapkin'), null, 1, 'bin'), app.to_loads(pg_temp.id('gNapkin'), null, 1, 'basket')],
  array[null, null]::numeric[], 'no factor → null, never a guess');
select is(array[app.queue_loads_needed(pg_temp.id('gTowel'), null, 0.25, 'bin'), app.queue_loads_needed(pg_temp.id('gNapkin'), null, 1, 'bin')],
  array[1, null], 'queue loads needed: ceil for bins; null without a factor (completed by hand)');
select is(pg_temp.run_as('ownerB', $$select 1 where app.to_loads(pg_temp.id('gTowel'), null, 1, 'bin') is null$$, true), '1',
  'to_loads runs with the caller''s RLS: another tenant gets null, not plant A''s factor');

-- ══ Estimates in bins ════════════════════════════════════════════════════
insert into public.entry_staff (id, org_id, plant_id, display_name, pin_hash) values
  ('b0000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Ben', extensions.crypt('1470', extensions.gen_salt('bf')));
create function pg_temp.ben() returns uuid language sql as $$
  select (public.start_staff_session('b0000000-0000-0000-0000-0000000000a2', '1470')).staff_session_id;
$$;
grant execute on function pg_temp.ben() to authenticated, anon;
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gTowel'), 2.75, 'bin', gen_random_uuid(), pg_temp.ben())$$),
  '1', 'record_soil_estimate: 2¾ bins for a group that allows bins');
select is((select array[qty_loads::text, has_conversion::text] from public.current_soil_estimates where wash_group_id = pg_temp.id('gTowel')),
  array['6.87500', 'true'], 'current_soil_estimates: bins converted via loads_per_bin');
select is(array[pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 1, 'bin', gen_random_uuid(), pg_temp.ben())$$),
                pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gTowel'), 1, 'piece', gen_random_uuid(), pg_temp.ben())$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED}', 'rejects bins for a group without bins allowed, and non-container units');
select is(pg_temp.as_service($$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 1, 'bin', pg_temp.id('owner'), gen_random_uuid())$$),
  'VALIDATION_FAILED', 'the estimate trigger rejects bins where not allowed (any write path)');
select is(pg_temp.as_service($$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 1, 'piece', pg_temp.id('owner'), gen_random_uuid())$$),
  '23514', 'soil_estimates unit CHECK: load, basket or bin');

-- ══ Setup edits: new factors editable, the deprecated one is not ═════════
select is(pg_temp.writes($$update public.wash_groups set loads_per_bin = 2, allow_bin_estimates = true, loads_per_basket = 0.5 where id = pg_temp.id('gTowel')$$),
  '{1,1,0,0,0,0,0,42501}', 'loads per basket / bin: the owner edits; the manager''s identical values change nothing (others: no rows; see 192)');
select is(pg_temp.run_as('owner', $$update public.wash_groups set baskets_per_load = 3 where id = pg_temp.id('gTowel')$$),
  '42501', 'baskets_per_load is deprecated: not client-editable');
select is((select array[after ->> 'loads_per_bin', actor_user_id::text] from public.audit_log
            where entity = 'wash_groups' and entity_id = pg_temp.id('gTowel') and action = 'wash_groups.update'
              and before ->> 'loads_per_bin' = '2.500'),
  array['2.000', pg_temp.id('owner')::text], 'factor edits are audited');

-- ══ ADB seed: factors and colors (seed.sql = the data migration's values) ══
create function pg_temp.adb(p_name text) returns public.wash_groups language sql stable as $$
  select g.* from public.wash_groups g
    join public.plants p on p.id = g.plant_id and p.name = 'Miami'
    join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
   where g.name = p_name and g.customer_id is null;   -- our own goods (AA Linen has its own groups)
$$;
create function pg_temp.adb_groups() returns setof public.wash_groups language sql stable as $$
  select g.* from public.wash_groups g
    join public.plants p on p.id = g.plant_id and p.name = 'Miami'
    join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
   where g.customer_id is null;   -- our own goods; AA Linen's groups are checked below
$$;
-- Every group of the plant, ours and outside customers' (chip colors must be distinct and readable).
create function pg_temp.adb_all_groups() returns setof public.wash_groups language sql stable as $$
  select g.* from public.wash_groups g
    join public.plants p on p.id = g.plant_id and p.name = 'Miami'
    join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters';
$$;
select is((select array_agg(name order by name) from pg_temp.adb_groups() where loads_per_basket = 3.5 and allow_basket_estimates),
  array['Black mats','Charcoal mats','City & Brito mats','Colored mats','Logo mats','Presidente logo mats','Scraper mats'],
  'every mat group: 3.5 loads per basket, baskets allowed');
select is((select array[loads_per_basket, loads_per_bin] from pg_temp.adb('Kitchen towels')), array[2, 2.5]::numeric[],
  'Kitchen towels: 2 loads per basket, 2.5 per bin');
select is((select count(*)::int from pg_temp.adb_groups()
            where loads_per_bin = 2 and allow_bin_estimates
              and (name like 'Napkins – %' or name like '% sheets' or name like '% tablecloths')), 18,
  'all 12 napkin groups (14 colors: green + red and bone + chambray wash together), 3 sheet groups and 3 tablecloth groups: 2 loads per bin, bins allowed');
select is((select array_agg(name order by name) from pg_temp.adb_groups() where loads_per_basket is null and loads_per_bin is null),
  array['Black aprons','Coats (white)','Dust & wet mops','Mechanic towels','Microfiber mops','Microfiber towels','White aprons'],
  'every other group: no factor (null, never guessed)');
select is((select array[count(*), count(distinct color_hex), count(*) filter (where color_hex = '#64748B')]::int[] from pg_temp.adb_groups()),
  array[33, 33, 0], '33 groups, 33 distinct preset colors, none left at the default');
select is((select array[count(*), count(distinct color_hex), count(*) filter (where color_hex = '#64748B')]::int[] from pg_temp.adb_all_groups()),
  array[45, 45, 0], 'with AA Linen''s 12 groups (2026-11-07): 45 groups, 45 distinct preset colors (AA chips never look like ours)');

-- Chip contrast: every color is ≥ 3:1 against the white card or the TV's dark card (#0B0F14);
-- colors whose name has no black/white/navy/bone/sheet meaning are ≥ 3:1 against both.
create function pg_temp.lum(p_hex text) returns numeric language sql immutable as $$
  select 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3]
    from (select array_agg(case when v <= 0.04045 then v / 12.92 else power((v + 0.055) / 1.055, 2.4) end order by i) as c
            from (select i, ('x' || substr(p_hex, 2 * i, 2))::bit(8)::int / 255.0 as v from generate_series(1, 3) i) x) y;
$$;
create function pg_temp.contrast(a text, b text) returns numeric language sql immutable as $$
  select (greatest(pg_temp.lum(a), pg_temp.lum(b)) + 0.05) / (least(pg_temp.lum(a), pg_temp.lum(b)) + 0.05);
$$;
select is((select coalesce(array_agg(name order by name), '{}') from pg_temp.adb_all_groups()
            where pg_temp.contrast(color_hex, '#FFFFFF') < 3 and pg_temp.contrast(color_hex, '#0B0F14') < 3),
  '{}'::text[], 'every chip is ≥ 3:1 against a white or a dark card');
select is((select coalesce(array_agg(name order by name), '{}') from pg_temp.adb_all_groups()
            where name !~* '(black|white|navy|bone|sheets|charcoal)'
              and (pg_temp.contrast(color_hex, '#FFFFFF') < 3 or pg_temp.contrast(color_hex, '#0B0F14') < 3)),
  '{}'::text[], 'colored and no-color groups are ≥ 3:1 against both cards');

select is((select array_agg(name order by name) from pg_temp.adb_groups() where loads_per_bin = 4 and allow_bin_estimates),
  array['Black mats','Charcoal mats','City & Brito mats','Colored mats','Logo mats','Presidente logo mats','Scraper mats'],
  'owner 2026-11-05: every mat group also takes 4 loads per full bin (bins allowed)');
select is((select array_agg(name_i18n ->> 'es' order by name) from pg_temp.adb_groups() where name like '%mops'),
  array['Mapos de polvo y trapeadores', 'Mapos de microfibra'], 'owner 2026-11-05: mops are "Mapos" in Spanish');

select * from finish();
rollback;
