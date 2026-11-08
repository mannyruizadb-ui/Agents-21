-- One sign-in method (owner 2026-11-07; 20261107021211): record_soil_estimate, record_finished_goods and
-- record_customer_delivery need no name + PIN. p_staff_session_id is optional and ignored (the deployed app
-- still sends it), staff_id is null, entered_by = the account; the finished-goods shift is the area's clock
-- shift (app.clock_entry_shift); owner-only names fall back to the profile name, else the username, never
-- an email. Role checks are unchanged.
begin;
\ir _fixtures.psql
select plan(12);

insert into public.customers (id, org_id, plant_id, name) values
  ('c1000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'AA Test');
insert into public.wash_groups (id, org_id, plant_id, customer_id, name) values
  ('71000000-0000-0000-0000-0000000aa0a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1', 'AA towels');

-- ══ Signatures: the session argument can be left out ═════════════════════
select is(array(select p.proname::text || ':' || (p.proargdefaults is not null)::text || ':' || p.pronargdefaults
                  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname in ('record_soil_estimate', 'record_finished_goods', 'record_customer_delivery')
                 order by p.proname),
  '{record_customer_delivery:true:3,record_finished_goods:true:8,record_soil_estimate:true:3}',
  'one overload each; p_staff_session_id and everything after it have defaults');
select is(array[
  pg_temp.run_as('manager', $$select public.record_soil_estimate(p_wash_group_id => pg_temp.id('gNapkin'), p_qty => 2, p_unit => 'load', p_client_id => 'e7000000-0000-0000-0000-000000000001')$$),
  pg_temp.run_as('manager', $$select public.record_finished_goods(p_item_type_id => pg_temp.id('mat'), p_packs => 0, p_loose_pieces => 4, p_client_id => 'e7000000-0000-0000-0000-000000000002')$$),
  pg_temp.run_as('owner',   $$select public.record_customer_delivery(p_plant_id => pg_temp.id('plantA'), p_customer_id => 'c1000000-0000-0000-0000-0000000000a1',
                               p_lines => '[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":1}]', p_client_id => 'e7000000-0000-0000-0000-000000000003')$$)],
  '{1,1,1}', 'each RPC records without any staff session argument (named arguments, as supabase-js calls them)');
select is(array[
  (select (staff_id is null and entered_by = pg_temp.id('manager'))::text from public.soil_estimates where client_id = 'e7000000-0000-0000-0000-000000000001'),
  (select (staff_id is null and entered_by = pg_temp.id('manager'))::text from public.finished_goods_entries where client_id = 'e7000000-0000-0000-0000-000000000002'),
  (select (staff_id is null and entered_by = pg_temp.id('owner'))::text from public.customer_deliveries where client_id = 'e7000000-0000-0000-0000-000000000003')],
  '{true,true,true}', 'the account is the attribution: entered_by set, staff_id null');
select is(array[
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 2, 'load', gen_random_uuid(), gen_random_uuid())$$),
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 1, gen_random_uuid(), gen_random_uuid())$$)],
  '{1,1}', 'an unknown session id (the old app) is ignored, never STAFF_SESSION_REQUIRED');
select ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'public' and p.proname in ('record_soil_estimate', 'record_finished_goods', 'record_customer_delivery')
                         and (p.prosrc like '%use_staff_session%' or p.prosrc like '%STAFF_SESSION_REQUIRED%')),
  'none of the three uses a staff session any more');

-- ══ Roles unchanged ══════════════════════════════════════════════════════
select is(pg_temp.writes($$select public.record_soil_estimate(pg_temp.id('gTowel'), 0, 'load', gen_random_uuid())$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'estimates: owner and manager only (lead, viewer, display, other tenant refused; anon cannot call)');
select is(pg_temp.writes($$select public.record_finished_goods(pg_temp.id('mat'), 0, 1, gen_random_uuid())$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'finished goods: owner and manager only (a lead or viewer still cannot write finished goods)');

-- ══ Shift: the area's clock shift ════════════════════════════════════════
select is(array[app.clock_entry_shift('own', pg_temp.ny('2026-11-03 11:30'), pg_temp.id('fin')),
                app.clock_entry_shift('next', pg_temp.ny('2026-11-03 01:00'), pg_temp.id('fin')),
                app.clock_entry_shift(null, pg_temp.ny('2026-11-03 01:00'), pg_temp.id('fin'))],
  array[pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03'), pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03'), pg_temp.si(pg_temp.id('fin'), 'Night', '2026-11-03')],
  'own = the instance at that time; next = the one after it; null choice = own');
select is(array[pg_temp.as_service($$select app.clock_entry_shift('later', now(), pg_temp.id('fin'))$$),
                pg_temp.as_service($$select app.clock_entry_shift('own', null, pg_temp.id('fin'))$$),
                has_function_privilege('authenticated', 'app.clock_entry_shift(text,timestamptz,uuid)', 'execute')::text],
  '{VALIDATION_FAILED,VALIDATION_FAILED,false}', 'clock_entry_shift: own|next, a time and an area required; internal');

-- ══ Owner-only names without a PIN person ════════════════════════════════
update auth.users set email = 'denise@accounts.adbheadquarters.com' where id = pg_temp.id('lead');
select is(array[app.person_name(pg_temp.id('manager'), null, pg_temp.id('plantA')),
                app.person_name(pg_temp.id('lead'), null, pg_temp.id('plantA')),
                coalesce(app.person_name(pg_temp.id('viewer'), null, pg_temp.id('plantA')), 'null')],
  '{"Manager A",denise,"null"}', 'app.person_name: the profile name, else the username of a mapped login, else nothing (never part of an email)');
select is(pg_temp.val_as('owner', $$select entered_by_name from public.get_customer_deliveries(pg_temp.id('plantA')) limit 1$$), 'Owner A',
  'owner screens show the account''s name for a delivery entered without a PIN');
select is(pg_temp.run_as('manager', $$select * from public.get_customer_deliveries(pg_temp.id('plantA'))$$), 'NOT_AUTHORIZED',
  'managers still never see names');

select * from finish();
rollback;
