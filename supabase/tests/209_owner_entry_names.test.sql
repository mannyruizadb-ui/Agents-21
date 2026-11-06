-- Owner 2026-11-06 (D): "entered by" names on OWNER screens only. Owner reads carry the name; every
-- other role gets null (or is refused by an owner-only read). Who-entered columns stay unselectable.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(22);

insert into public.entry_staff (id, org_id, plant_id, display_name) values
  ('e0000000-0000-0000-0000-000000000001', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Denise P');
select set_config('test.today', ((now() at time zone 'America/New_York')::date)::text, true);
insert into public.routes (id, org_id, plant_id, name, load_time, days_of_week) values
  ('a1000000-0000-0000-0000-000000000001', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Route Daily', '05:00', '{0,1,2,3,4,5,6}');
update public.memberships set can_enter_load_out = true where user_id = pg_temp.id('manager');

-- ══ Queue: who added the item ════════════════════════════════════════════
select is(pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 2, 'load', gen_random_uuid(), pg_temp.id('gNapkin'))$$), '1', 'the owner queues napkins');
select is(pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'), p_is_rewash => true)$$), '1', 'a manager adds a rewash');
select is(pg_temp.val_as('owner', $$select string_agg(wash_group_name || '=' || created_by_name, ',' order by wash_group_name) from public.get_queue(pg_temp.id('wash'))$$),
  'Mats=Manager A,Napkins=Owner A', 'get_queue: the owner sees who added each item');
select is(pg_temp.reads($$select 1 from public.get_queue(pg_temp.id('wash')) where created_by_name is not null$$),
  '{2,0,0,0,0,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'get_queue: names for owners only (manager, lead, viewer, display: null)');

-- ══ Machine down / fixed ═════════════════════════════════════════════════
select is(pg_temp.run_as('manager', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), 'belt', 'leaking')$$), '1', 'the manager marks Washer 1 down');
select is(pg_temp.val_as('owner', $$select status::text || '/' || status_by_name from public.get_machine_status(pg_temp.id('plantA')) where machine_id = pg_temp.id('machine')$$),
  'down/Manager A', 'get_machine_status: the owner sees who marked it');
select is(pg_temp.reads($$select 1 from public.get_machine_status(pg_temp.id('plantA')) where status_by_name is not null$$),
  '{1,0,0,0,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'get_machine_status: names for owners only');
select is(pg_temp.run_as('owner', $$select public.set_machine_status(pg_temp.id('machine'), 'up', gen_random_uuid())$$), '1', 'the owner marks it fixed');
select is(pg_temp.val_as('owner', $$select string_agg(status::text || '=' || entered_by_name, ',' order by status) from public.get_machine_status_history(pg_temp.id('plantA'))$$),
  'down=Manager A,up=Owner A', 'get_machine_status_history: down and fixed events with names');
select is(pg_temp.writes($$select * from public.get_machine_status_history(pg_temp.id('plantA'))$$),
  '{2,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'history: owner only, no cross-tenant');

-- ══ Load-out ═════════════════════════════════════════════════════════════
select is(pg_temp.val_as('manager', $$select coalesce((r).entered_by::text, 'hidden') from (select public.set_load_out_line(pg_temp.id('plantA'), current_setting('test.today')::date, 'a1000000-0000-0000-0000-000000000001', 4, pg_temp.id('napkin')) r) x$$),
  'hidden', 'the office manager types a line; the returned row hides who typed it');
select is(pg_temp.run_as('owner', $$select public.mark_route_loaded('a1000000-0000-0000-0000-000000000001', current_setting('test.today')::date, gen_random_uuid())$$), '1', 'the owner marks the route loaded');
select is(pg_temp.val_as('owner', $$select (r -> 'lines' -> 0 ->> 'entered_by_name') || '/' || (r ->> 'loaded_by_name')
                                       from jsonb_array_elements(public.get_load_out_board(pg_temp.id('plantA'), current_setting('test.today')::date) -> 'routes') r$$),
  'Manager A/Owner A', 'owner board: who typed each line and who marked it loaded');
select is(array(select pg_temp.val_as(u, $$select concat(r -> 'lines' -> 0 ->> 'entered_by_name', r ->> 'loaded_by_name')
                                             from jsonb_array_elements(public.get_load_out_board(pg_temp.id('plantA'), current_setting('test.today')::date) -> 'routes') r$$)
                 from unnest(array['manager', 'lead', 'viewer']) u),
  array['', '', ''], 'manager, lead and viewer boards: names are null');
select is(pg_temp.val_as('owner', $$select public.copy_load_out_from(pg_temp.id('plantA'), current_setting('test.today')::date, current_setting('test.today')::date + 1)::text$$), '1', 'the owner copies it to tomorrow');
select is(pg_temp.val_as('owner', $$select r -> 'lines' -> 0 ->> 'entered_by_name'
                                     from jsonb_array_elements(public.get_load_out_board(pg_temp.id('plantA'), current_setting('test.today')::date + 1) -> 'routes') r$$),
  'Owner A', 'a copied line is attributed to whoever copied it');
select is(array[pg_temp.run_as('owner', $$select entered_by from public.load_out_lines$$),
                pg_temp.run_as('manager', $$select id, qty, load_date from public.load_out_lines$$, true)],
  '{42501,2}', 'load_out_lines.entered_by is never selectable; the other columns are');

-- ══ Soil estimates (PIN-attributed) ══════════════════════════════════════
insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, staff_id, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 3, 'load', pg_temp.id('manager'), 'e0000000-0000-0000-0000-000000000001', gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'), 2, 'load', pg_temp.id('owner'), null, gen_random_uuid());
select is(pg_temp.val_as('owner', $$select string_agg(wash_group_name || '=' || qty::int || '/' || entered_by_name, ',' order by wash_group_name) from public.get_soil_estimate_entries(pg_temp.id('plantA'))$$),
  'Mats=2/Owner A,Napkins=3/Denise P', 'get_soil_estimate_entries: entry staff name for PIN entries, else the account name');
select is(pg_temp.writes($$select * from public.get_soil_estimate_entries(pg_temp.id('plantA'))$$),
  '{2,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'estimate entries: owner only, no cross-tenant');

-- ══ Finished goods ═══════════════════════════════════════════════════════
insert into public.finished_goods_entries (id, org_id, plant_id, area_id, item_type_id, loose_pieces, entered_by, staff_id, client_id, shift_instance_id)
values ('f0000000-0000-0000-0000-000000000001', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 7, pg_temp.id('manager'),
        'e0000000-0000-0000-0000-000000000001', gen_random_uuid(), pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-04'));
select set_config('test.pd', (select production_date::text from public.finished_goods_entries where id = 'f0000000-0000-0000-0000-000000000001'), true);
select is(pg_temp.run_as('owner', $$select public.void_finished_goods('f0000000-0000-0000-0000-000000000001', 'typo')$$), '1', 'the owner voids it');
select is(pg_temp.val_as('owner', $$select pieces || '/' || entered_by_name || '/' || voided_by_name from public.get_finished_goods_entries(pg_temp.id('plantA'), current_setting('test.pd')::date)$$),
  '7/Denise P/Owner A', 'get_finished_goods_entries: who entered (PIN name) and who voided');
select is(pg_temp.writes($$select * from public.get_finished_goods_entries(pg_temp.id('plantA'), current_setting('test.pd')::date)$$),
  '{1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'finished-goods entries: owner only, no cross-tenant');

select * from finish();
rollback;
