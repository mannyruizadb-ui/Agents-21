-- Mats are "Alfombras" in Spanish (owner 2026-11-09; 20261109212849, app.apply_mat_spanish_names): no active
-- ADB mat group or mat item still has an es name containing "Tapete"; the exact names; AA Linen's "Alfombras"
-- untouched; other i18n keys kept; owner edits never overwritten; idempotent; audited; guards.
begin;
\ir _fixtures.psql
select plan(13);

create function pg_temp.adb() returns uuid language sql stable as $$
  select p.id from public.plants p
    join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
   where p.name = 'Miami';
$$;
create function pg_temp.g(p_name text) returns uuid language sql stable as $$
  select g.id from public.wash_groups g where g.plant_id = pg_temp.adb() and g.customer_id is null and g.name = p_name;
$$;
create function pg_temp.i(p_name text) returns uuid language sql stable as $$
  select i.id from public.item_types i where i.plant_id = pg_temp.adb() and i.name = p_name;
$$;

-- ══ The owner's rule ═════════════════════════════════════════════════════
select is((select count(*)::int from public.wash_groups g
            where g.plant_id = pg_temp.adb() and g.category = 'mats' and g.active
              and g.name_i18n ->> 'es' ilike '%tapete%')
        + (select count(*)::int from public.item_types i
            where i.plant_id = pg_temp.adb() and i.category = 'mat' and i.active
              and i.name_i18n ->> 'es' ilike '%tapete%'),
  0, 'no active ADB mat group or mat item has an es name containing "Tapete"');
select is((select count(*)::int from public.wash_groups g where g.plant_id = pg_temp.adb() and g.name_i18n ->> 'es' ilike '%tapete%')
        + (select count(*)::int from public.item_types i where i.plant_id = pg_temp.adb() and i.name_i18n ->> 'es' ilike '%tapete%'),
  0, 'nor any inactive group or item, nor any other category');

-- ══ Exact names (owner's wording) ════════════════════════════════════════
select is((select array_agg(g.name || ' = ' || (g.name_i18n ->> 'es') order by g.sort_order) from public.wash_groups g
            where g.plant_id = pg_temp.adb() and g.customer_id is null and g.category = 'mats'),
  array['Black mats = Alfombras negras', 'Colored mats = Alfombras de color', 'Charcoal mats = Alfombras carbón',
        'Scraper mats = Alfombras raspadoras', 'Brito mats = Alfombras Brito',
        'Presidente logo mats = Alfombras con logo Presidente', 'Logo mats = Alfombras con logo'],
  'our 7 mat groups (4 active baskets + 3 deactivated): Alfombras …');
select is((select array_agg(i.name || ' = ' || (i.name_i18n ->> 'es') order by i.sort_order) from public.item_types i
            where i.plant_id = pg_temp.adb() and i.category = 'mat'),
  array['Black mat 2×3 = Alfombra negra 2×3', 'Black mat 3×5 = Alfombra negra 3×5', 'Black mat 4×6 = Alfombra negra 4×6',
        'Black mat 3×10 = Alfombra negra 3×10', 'Black mat 5×7 = Alfombra negra 5×7',
        'Colored mat 2×3 = Alfombra de color 2×3', 'Colored mat 3×5 = Alfombra de color 3×5',
        'Colored mat 4×6 = Alfombra de color 4×6', 'Colored mat 3×10 = Alfombra de color 3×10',
        'Colored mat 5×7 = Alfombra de color 5×7', 'Charcoal mat 4×6 = Alfombra carbón 4×6',
        'Scraper mat 3×5 = Alfombra raspadora 3×5',
        'Black City mat 3×5 = Alfombra City negra 3×5', 'Black City mat 4×6 = Alfombra City negra 4×6',
        'Black City mat 3×10 = Alfombra City negra 3×10',
        'Red Brito mat 4×6 = Alfombra Brito roja 4×6', 'Red Brito mat 3×10 = Alfombra Brito roja 3×10',
        'Presidente logo mat 5×7 = Alfombra con logo Presidente 5×7',
        'Logo mat 3×5 = Alfombra con logo 3×5', 'Logo mat 4×6 = Alfombra con logo 4×6', 'Logo mat 5×7 = Alfombra con logo 5×7'],
  'the 21 mat items: Alfombra … (feminine adjectives, sizes kept)');
select is((select g.name_i18n ->> 'es' from public.wash_groups g
             join public.customers c on c.id = g.customer_id and c.name = 'AA Linen'
            where g.plant_id = pg_temp.adb() and g.name = 'Mats'), 'Alfombras', 'AA Linen''s Mats stays "Alfombras"');

-- ══ Audit (seed ran the same function as the cloud migration, as postgres: no actor) ══
select is((select array[a.before -> 'name_i18n' ->> 'es', a.after -> 'name_i18n' ->> 'es', coalesce(a.actor_user_id::text, 'null')]
             from public.audit_log a
            where a.entity = 'item_types' and a.entity_id = pg_temp.i('Black mat 3×5') and a.action = 'item_types.update'
              and a.after -> 'name_i18n' ->> 'es' = 'Alfombra negra 3×5'),
  array['Tapete negro 3×5', 'Alfombra negra 3×5', 'null'], 'the rename is audited (no actor: a data change)');

-- ══ Idempotent ═══════════════════════════════════════════════════════════
create temp table audit_before as select count(*) as n from public.audit_log;
select is(app.apply_mat_spanish_names(pg_temp.adb()),
  '{"groups_renamed": 0, "items_renamed": 0, "tapete_left": []}'::jsonb, 'a re-run changes nothing');
select is((select count(*) from public.audit_log), (select n from audit_before), 'and writes no audit row');

-- ══ Replay on the old names; owner edits and other keys are kept ═════════
update public.wash_groups set name_i18n = '{"en":"Brito baskets","es":"Tapetes Brito"}' where id = pg_temp.g('Brito mats');
update public.item_types  set name_i18n = '{"es":"Tapete Brito rojo 4×6"}' where id = pg_temp.i('Red Brito mat 4×6');
update public.item_types  set name_i18n = '{"es":"Tapete raspador 3×5"}'  where id = pg_temp.i('Scraper mat 3×5');
-- An owner edit that does not START with "Tapete" is never touched (reported instead).
update public.item_types  set name_i18n = '{"es":"Alfombrita negra 2×3 (Tapete chico)"}' where id = pg_temp.i('Black mat 2×3');
select is(app.apply_mat_spanish_names(pg_temp.adb()),
  '{"groups_renamed": 1, "items_renamed": 2, "tapete_left": ["Alfombrita negra 2×3 (Tapete chico)"]}'::jsonb,
  'replay: only es values starting with "Tapete" change; an owner edit is kept and reported');
select is(array[(select name_i18n::text from public.wash_groups where id = pg_temp.g('Brito mats')),
                (select name_i18n ->> 'es' from public.item_types where id = pg_temp.i('Red Brito mat 4×6')),
                (select name_i18n ->> 'es' from public.item_types where id = pg_temp.i('Scraper mat 3×5')),
                (select name_i18n ->> 'es' from public.item_types where id = pg_temp.i('Black mat 2×3'))],
  array['{"en": "Brito baskets", "es": "Alfombras Brito"}', 'Alfombra Brito roja 4×6', 'Alfombra raspadora 3×5',
        'Alfombrita negra 2×3 (Tapete chico)'],
  'renamed with agreement; other i18n keys kept; owner edit untouched');

-- ══ The transform ════════════════════════════════════════════════════════
select is(array[app.es_mat_alfombra('Tapetes negros'), app.es_mat_alfombra('Tapete blanco nuevo 3×5'),
                app.es_mat_alfombra('Tapetes rojos y negros'), app.es_mat_alfombra('Toalla negro'),
                app.es_mat_alfombra('Tapetero negro'), app.es_mat_alfombra(null)],
  array['Alfombras negras', 'Alfombra blanca nueva 3×5', 'Alfombras rojas y negras', 'Toalla negro',
        'Tapetero negro', null],
  'es_mat_alfombra: only a leading "Tapete(s)" word is changed, with feminine adjectives; anything else as is');

-- ══ Guards ═══════════════════════════════════════════════════════════════
select is(array[pg_temp.as_service($$select app.apply_mat_spanish_names(gen_random_uuid())$$),
                pg_temp.as_service($$select app.apply_mat_spanish_names(null)$$)],
  array['VALIDATION_FAILED', 'VALIDATION_FAILED'], 'an unknown plant, or no plant: VALIDATION_FAILED');
select is(array[has_function_privilege('authenticated', 'app.apply_mat_spanish_names(uuid)', 'execute'),
                has_function_privilege('anon', 'app.apply_mat_spanish_names(uuid)', 'execute'),
                has_function_privilege('authenticated', 'app.es_mat_alfombra(text)', 'execute'),
                has_function_privilege('anon', 'app.es_mat_alfombra(text)', 'execute')],
  array[false, false, false, false], 'not callable by authenticated or anon');

select * from finish();
rollback;
