-- Mats by basket (owner 2026-11-09; 20261109184351, app.apply_mat_basket_groups): the ADB plant's own mat
-- groups are the 4 baskets (Black, Colored, Charcoal, Brito mats); Scraper, Presidente logo and Logo mats
-- are inactive and empty; the changes are audited; the function is idempotent, leaves open queue items and
-- estimates of the deactivated groups as they are (and reports them), fails loudly on a catalog it does not
-- recognise, and is not callable through the API. seed.sql runs the same function as the cloud migration.
begin;
\ir _fixtures.psql
select plan(19);

create function pg_temp.adb() returns uuid language sql stable as $$
  select p.id from public.plants p
    join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
   where p.name = 'Miami';
$$;
create function pg_temp.g(p_name text) returns uuid language sql stable as $$
  select g.id from public.wash_groups g where g.plant_id = pg_temp.adb() and g.customer_id is null and g.name = p_name;
$$;
-- "<group>: item, item, …" for our own mat groups (active or not), so one assertion shows the whole catalog.
create function pg_temp.mat_catalog(p_active boolean) returns text[] language sql stable as $$
  select coalesce(array_agg(x.line order by x.name), '{}') from (
    select g.name, g.name || ': ' || coalesce((select string_agg(i.name, ', ' order by i.sort_order)
                                                 from public.item_types i where i.wash_group_id = g.id), '-') as line
      from public.wash_groups g
     where g.plant_id = pg_temp.adb() and g.customer_id is null and g.category = 'mats' and g.active = p_active) x;
$$;

-- ══ Final state (fresh database: seed + the function) ════════════════════
select is(pg_temp.mat_catalog(true), array[
  'Black mats: Black mat 2×3, Black mat 3×5, Black mat 4×6, Black mat 3×10, Black mat 5×7, Scraper mat 3×5, Black City mat 3×5, Black City mat 4×6, Black City mat 3×10',
  'Brito mats: Red Brito mat 4×6, Red Brito mat 3×10',
  'Charcoal mats: Charcoal mat 4×6',
  'Colored mats: Colored mat 2×3, Colored mat 3×5, Colored mat 4×6, Colored mat 3×10, Colored mat 5×7, Presidente logo mat 5×7, Logo mat 3×5, Logo mat 4×6, Logo mat 5×7'],
  '4 active mat baskets with their items: black (+ Black City, scraper), colored (+ Presidente and other logos), charcoal, Brito (red Brito only)');
select is(pg_temp.mat_catalog(false),
  array['Logo mats: -', 'Presidente logo mats: -', 'Scraper mats: -'],
  'Scraper, Presidente logo and Logo mats: deactivated (kept, never deleted) and empty');
select is((select count(*)::int from public.wash_groups g where g.plant_id = pg_temp.adb() and g.name = 'City & Brito mats'), 0,
  'no group is still called City & Brito mats');
select is((select array[g.name_i18n ->> 'es', g.color_hex] from public.wash_groups g where g.id = pg_temp.g('Brito mats')),
  -- es is "Alfombras Brito" since 20261109212849 (mats are Alfombras); this function set "Tapetes Brito" (audit below).
  array['Alfombras Brito', '#EF4444'], 'Brito mats: es "Alfombras Brito" (after 20261109212849), red preset (was teal #0F766E)');
select is((select array_agg(g.name || ':' || f.external_no || ':' || g.category || ':' || g.loads_per_basket::text || ':' || g.loads_per_bin::text
                            || ':' || g.allow_basket_estimates::text || ':' || g.allow_bin_estimates::text
                            || ':' || g.default_estimate_unit::text order by g.name)
             from public.wash_groups g join public.wash_formulas f on f.id = g.wash_formula_id
            where g.plant_id = pg_temp.adb() and g.customer_id is null and g.category = 'mats' and g.active),
  array['Black mats:1:mats:3.500:4.000:true:true:basket', 'Brito mats:1:mats:3.500:4.000:true:true:basket',
        'Charcoal mats:1:mats:3.500:4.000:true:true:basket', 'Colored mats:1:mats:3.500:4.000:true:true:basket'],
  'the 4 baskets: formula 1, category mats, 3.5 loads per basket and 4 per bin, both containers allowed, estimated by the basket');
select is((select array_agg(g.color_hex order by g.name) from public.wash_groups g
            where g.plant_id = pg_temp.adb() and g.customer_id is null and g.category = 'mats' and g.active),
  array['#000000', '#EF4444', '#52525B', '#DC2626'],
  'the 4 baskets'' colours: Black #000000 and Colored red #DC2626 since the fabric colours (owner 2026-11-10), Brito #EF4444, Charcoal');
select is((select count(*)::int from public.wash_groups g where g.plant_id = pg_temp.adb() and g.color_hex = '#EF4444'), 1,
  'no other group of the plant (ours or AA Linen''s) uses Brito''s red');
select is((select g.active::text || ':' || g.category from public.wash_groups g
             join public.customers c on c.id = g.customer_id and c.name = 'AA Linen'
            where g.plant_id = pg_temp.adb() and g.name = 'Mats'), 'true:mats', 'AA Linen''s Mats group is untouched');

-- ══ Audit (the seed ran the same function as the cloud migration, as postgres: no actor) ══
select is((select array[before ->> 'name', after ->> 'name', after -> 'name_i18n' ->> 'es', coalesce(actor_user_id::text, 'null')]
             from public.audit_log
            where entity = 'wash_groups' and entity_id = pg_temp.g('Brito mats') and action = 'wash_groups.update'
              and before ->> 'name' = 'City & Brito mats' and after ->> 'name' = 'Brito mats'),
  array['City & Brito mats', 'Brito mats', 'Tapetes Brito', 'null'], 'the rename is audited (no actor: a data change)');
select is((select array_agg(g.name order by g.name) from public.audit_log a join public.wash_groups g on g.id = a.entity_id
            where a.entity = 'wash_groups' and a.action = 'wash_groups.update'
              and a.before ->> 'active' = 'true' and a.after ->> 'active' = 'false' and g.plant_id = pg_temp.adb()),
  array['Logo mats', 'Presidente logo mats', 'Scraper mats'], 'each deactivation is audited');
select is((select array_agg(g.name order by g.name) from public.audit_log a join public.wash_groups g on g.id = a.entity_id
            where a.entity = 'wash_groups' and a.action = 'wash_groups.update' and a.actor_user_id is null
              and a.before ->> 'default_estimate_unit' = 'load' and a.after ->> 'default_estimate_unit' = 'basket'
              and g.plant_id = pg_temp.adb()),
  array['Black mats', 'Brito mats', 'Charcoal mats', 'Colored mats'], 'the default unit change (load → basket) is audited for the 4 baskets');
select is((select array_agg(bg.name || ' → ' || ag.name || ': ' || (a.after ->> 'name') order by a.after ->> 'name')
             from public.audit_log a
             join public.wash_groups bg on bg.id = (a.before ->> 'wash_group_id')::uuid
             join public.wash_groups ag on ag.id = (a.after ->> 'wash_group_id')::uuid
            where a.entity = 'item_types' and a.action = 'item_types.update' and ag.plant_id = pg_temp.adb()
              and a.before ->> 'wash_group_id' is distinct from a.after ->> 'wash_group_id'),
  -- Group names are the groups' current names (the Brito group is the former City & Brito mats).
  array['Brito mats → Black mats: Black City mat 3×10', 'Brito mats → Black mats: Black City mat 3×5',
        'Brito mats → Black mats: Black City mat 4×6', 'Logo mats → Colored mats: Logo mat 3×5',
        'Logo mats → Colored mats: Logo mat 4×6', 'Logo mats → Colored mats: Logo mat 5×7',
        'Presidente logo mats → Colored mats: Presidente logo mat 5×7', 'Scraper mats → Black mats: Scraper mat 3×5'],
  'the 8 item moves are audited, each from the group the owner named');

-- ══ Idempotent: a second run changes nothing and writes no audit row ══════
create temp table audit_before as select count(*) as n from public.audit_log;
select is((select app.apply_mat_basket_groups(pg_temp.adb()) - 'items_left_in_inactive_groups'
                  - 'open_queue_items_in_inactive_groups' - 'open_queue_items_of_moved_items'
                  - 'latest_estimates_in_inactive_groups' - 'formulas_pointing_at_inactive_groups'),
  '{"renamed": 0, "items_moved": 0, "groups_updated": 0, "groups_deactivated": 0}'::jsonb, 'a re-run changes nothing');
select is((select count(*) from public.audit_log), (select n from audit_before), 'and writes no audit row');

-- ══ Replay on the old catalog with open work in a group it deactivates ═══
-- Back to the pre-2026-11-09 state (as the cloud is before the migration), plus an open queue item and a
-- non-zero estimate in Logo mats and an open queue item for a Logo mat 4×6 (an item that moves).
update public.wash_groups set name = 'City & Brito mats', name_i18n = name_i18n || '{"es":"Tapetes City y Brito"}', color_hex = '#0F766E'
 where id = pg_temp.g('Brito mats');
update public.wash_groups set active = true where id in (pg_temp.g('Scraper mats'), pg_temp.g('Presidente logo mats'), pg_temp.g('Logo mats'));
update public.wash_groups set default_estimate_unit = 'load'
 where id in (pg_temp.g('Black mats'), pg_temp.g('Colored mats'), pg_temp.g('Charcoal mats'), pg_temp.g('City & Brito mats'));
update public.item_types set wash_group_id = pg_temp.g('City & Brito mats') where plant_id = pg_temp.adb() and name like 'Black City mat %';
update public.item_types set wash_group_id = pg_temp.g('Scraper mats') where plant_id = pg_temp.adb() and name = 'Scraper mat 3×5';
update public.item_types set wash_group_id = pg_temp.g('Presidente logo mats') where plant_id = pg_temp.adb() and name = 'Presidente logo mat 5×7';
update public.item_types set wash_group_id = pg_temp.g('Logo mats') where plant_id = pg_temp.adb() and name like 'Logo mat %';
insert into public.queue_items (id, org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position, created_by, client_id)
select v.id::uuid, p.org_id, p.id, a.id, pg_temp.g('Logo mats'), v.item, 2, 'load', v.pos, pg_temp.id('owner'), gen_random_uuid()
  from public.plants p join public.areas a on a.plant_id = p.id and a.name = 'Washroom'
 cross join (values ('9e000000-0000-0000-0000-0000000000a1', null::uuid, 9001),
                    ('9e000000-0000-0000-0000-0000000000a2',
                     (select i.id from public.item_types i where i.plant_id = pg_temp.adb() and i.name = 'Logo mat 4×6'), 9002)) v(id, item, pos)
 where p.id = pg_temp.adb();
insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id)
select p.org_id, p.id, pg_temp.g('Logo mats'), 1.5, 'load', pg_temp.id('owner'), gen_random_uuid()
  from public.plants p where p.id = pg_temp.adb();

select is(app.apply_mat_basket_groups(pg_temp.adb()),
  '{"renamed": 1, "items_moved": 8, "groups_updated": 4, "groups_deactivated": 3, "items_left_in_inactive_groups": [],
    "open_queue_items_in_inactive_groups": 2, "open_queue_items_of_moved_items": 1,
    "latest_estimates_in_inactive_groups": 1, "formulas_pointing_at_inactive_groups": 0}'::jsonb,
  'replay on the old catalog: rename, 8 moves, 3 deactivations, 4 baskets updated (default unit, Brito''s colour); open work is counted and reported');
select is(pg_temp.mat_catalog(true) || pg_temp.mat_catalog(false),
  array[
    'Black mats: Black mat 2×3, Black mat 3×5, Black mat 4×6, Black mat 3×10, Black mat 5×7, Scraper mat 3×5, Black City mat 3×5, Black City mat 4×6, Black City mat 3×10',
    'Brito mats: Red Brito mat 4×6, Red Brito mat 3×10',
    'Charcoal mats: Charcoal mat 4×6',
    'Colored mats: Colored mat 2×3, Colored mat 3×5, Colored mat 4×6, Colored mat 3×10, Colored mat 5×7, Presidente logo mat 5×7, Logo mat 3×5, Logo mat 4×6, Logo mat 5×7',
    'Logo mats: -', 'Presidente logo mats: -', 'Scraper mats: -'],
  'the replay ends in exactly the seeded final state');
select is((select array_agg(q.status::text || ':' || g.name || ':' || g.active::text order by q.id) from public.queue_items q
             join public.wash_groups g on g.id = q.wash_group_id
            where q.id in ('9e000000-0000-0000-0000-0000000000a1', '9e000000-0000-0000-0000-0000000000a2')),
  array['queued:Logo mats:false', 'queued:Logo mats:false'], 'open queue items of a deactivated group are left as they are');

-- ══ Guards ═══════════════════════════════════════════════════════════════
select is(array[pg_temp.as_service($$select app.apply_mat_basket_groups(pg_temp.id('plantA'))$$),
                pg_temp.as_service($$select app.apply_mat_basket_groups(null)$$)],
  array['VALIDATION_FAILED', 'VALIDATION_FAILED'],
  'a plant without the 4 basket groups, or no plant: VALIDATION_FAILED, nothing half-applied');
select is(array[has_function_privilege('authenticated', 'app.apply_mat_basket_groups(uuid)', 'execute'),
                has_function_privilege('anon', 'app.apply_mat_basket_groups(uuid)', 'execute')],
  array[false, false], 'not callable by authenticated or anon');

select * from finish();
rollback;
