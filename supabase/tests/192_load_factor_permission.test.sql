-- Owner 2026-11-05: load factors are owner-only, plus managers the owner grants
-- (memberships.can_edit_load_factors). Owner 2026-11-09: ALL wash-group writes are owner-only (RLS), so the
-- grant no longer lets a manager change anything on wash_groups (it is moot; kept, still owner-set).
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(10);

select is(pg_temp.writes($$update public.wash_groups set loads_per_bin = loads_per_bin_new from (select coalesce(max(loads_per_bin), 1) + 1 as loads_per_bin_new from public.wash_groups where id = pg_temp.id('gNapkin')) x where id = pg_temp.id('gNapkin')$$),
  '{1,0,0,0,0,0,0,42501}', 'changing a load factor: owner only (2026-11-09: the manager updates no rows, RLS)');
select is(array[
  pg_temp.run_as('manager', $$update public.wash_groups set loads_per_basket = 9 where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('manager', $$update public.wash_groups set allow_basket_estimates = false where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('manager', $$update public.wash_groups set allow_bin_estimates = true, loads_per_bin = 2 where id = pg_temp.id('gMat')$$),
  pg_temp.run_as('manager', $$insert into public.wash_groups (org_id, plant_id, name, loads_per_bin) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'New with factor', 2)$$)],
  '{0,0,0,NOT_AUTHORIZED}', 'manager: no factor or allow-flag change (no rows), no new group with a factor (the factor guard refuses first)');
select is(array[
  pg_temp.run_as('manager', $$update public.wash_groups set sort_order = 7, ships_next_morning = true where id = pg_temp.id('gTowel')$$),
  pg_temp.run_as('manager', $$insert into public.wash_groups (org_id, plant_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'New without factor')$$)],
  '{0,42501}', 'manager (2026-11-09): no other wash-group setting and no new group either (owner-only RLS)');
select is(pg_temp.run_as('ownerB', $$update public.wash_groups set loads_per_basket = 9 where id = pg_temp.id('gTowel')$$), '0',
  'another tenant: no rows, no oracle');

-- The owner grants the manager.
select is(pg_temp.run_as('owner', $$update public.memberships set can_edit_load_factors = true where user_id = pg_temp.id('manager')$$), '1',
  'the owner grants can_edit_load_factors');
select is(pg_temp.run_as('manager', $$update public.wash_groups set loads_per_basket = 0.6 where id = pg_temp.id('gTowel')$$), '0',
  'even a granted manager cannot edit factors since 2026-11-09 (owner-only wash groups; the grant is moot)');
select is(pg_temp.run_as('manager', $$update public.memberships set can_edit_load_factors = true where user_id = pg_temp.id('manager')$$), '0',
  'a manager cannot grant it (memberships UPDATE is owner-only)');
select is(pg_temp.as_service($$update public.memberships set can_edit_load_factors = true where user_id = pg_temp.id('lead')$$), '23514',
  'only manager memberships can hold the grant');
update public.memberships set can_edit_load_factors = false where user_id = pg_temp.id('manager');
select is(pg_temp.run_as('manager', $$update public.wash_groups set loads_per_basket = 0.7 where id = pg_temp.id('gTowel')$$), '0',
  'without the grant, the manager is refused too (no rows)');
select is(array[has_function_privilege('authenticated', 'app.can_edit_load_factors(uuid)', 'execute'),
                has_function_privilege('anon', 'app.can_edit_load_factors(uuid)', 'execute')],
  array[false, false], 'the helper is internal');

select * from finish();
rollback;
