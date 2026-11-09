-- Queue "loads left" is unknown (null), not 0, when the loads needed are unknown (2026-11-09;
-- 20261109215629_fix_unknown_queue_loads_remaining): queue_board / get_queue loads_remaining and
-- get_washroom_board next_loads_remaining; known values unchanged; get_wash_group_pace totals unchanged.
begin;
\ir _fixtures.psql
select plan(9);

-- Mats (gMat) has no bin factor: 3 bins = unknown loads. Napkins: 3 loads, 1 started. Towels: 2 loads, 5 started
-- (over-run). The bin item is first in line for Washer 1.
insert into public.queue_items (id, org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id, loads_started, item_type_id) values
  ('e9000000-0000-0000-0000-000000000001', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gMat'),    3, 'bin',  1, pg_temp.id('owner'), gen_random_uuid(), 0, null),
  ('e9000000-0000-0000-0000-000000000002', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), 3, 'load', 2, pg_temp.id('owner'), gen_random_uuid(), 1, null),
  ('e9000000-0000-0000-0000-000000000003', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gTowel'),  2, 'load', 3, pg_temp.id('owner'), gen_random_uuid(), 5, null),
  ('e9000000-0000-0000-0000-000000000004', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'),  pg_temp.id('gNapkin'), 40, 'piece', 1, pg_temp.id('owner'), gen_random_uuid(), 0, pg_temp.id('napkin'));

select is((select array_agg(coalesce(loads_needed::text, 'null') || '/' || coalesce(loads_remaining::text, 'null') order by area_id, position)
             from public.queue_board where plant_id = pg_temp.id('plantA')),
  array['null/null', '3/2', '2/0', 'null/null'],
  'queue_board: unknown needed → unknown left (bins without a factor; pieces); known: needed − started, never below 0');
select is(pg_temp.val_as('owner', $$select string_agg(coalesce(loads_remaining::text, 'null'), ',' order by position) from public.get_queue(pg_temp.id('wash'))$$),
  'null,2,0', 'get_queue (owner) returns null for the unknown item');
select is(pg_temp.val_as('lead', $$select string_agg(coalesce(loads_remaining::text, 'null'), ',' order by position) from public.get_queue(pg_temp.id('wash'))$$),
  'null,2,0', '… and the same for a lead');
select is(pg_temp.val_as('display', $$select string_agg(coalesce(loads_remaining::text, 'null'), ',' order by position) from public.get_queue(pg_temp.id('wash'))$$),
  'null,2,0', '… and the washroom display');
select is(pg_temp.val_as('owner', $$select next_queue_item_id || '/' || coalesce(next_loads_remaining::text, 'null') from public.get_washroom_board(pg_temp.id('wash')) where machine_id = pg_temp.id('machine')$$),
  'e9000000-0000-0000-0000-000000000001/null', 'washroom board NEXT: the bin item, loads left unknown (was 0)');
select is(pg_temp.val_as('owner', $$select queue_open_items || '/' || queue_loads_remaining || '/' || queue_items_without_load_count
                                     from public.get_wash_group_pace(pg_temp.id('plantA'), (now() at time zone 'America/New_York')::date)
                                    where wash_group_id = pg_temp.id('gMat')$$),
  '1/0/1', 'pace: the unknown item adds nothing to loads left and is counted as without a load count (unchanged)');
select is(pg_temp.val_as('owner', $$select queue_loads_remaining::text from public.get_wash_group_pace(pg_temp.id('plantA'), (now() at time zone 'America/New_York')::date)
                                    where wash_group_id = pg_temp.id('gNapkin')$$),
  '2', 'pace: known loads left are summed as before (the finishing piece item has no load count)');
update public.queue_items set status = 'cancelled' where id = 'e9000000-0000-0000-0000-000000000001';
select is(pg_temp.val_as('display', $$select next_queue_item_id || '/' || coalesce(next_loads_remaining::text, 'null') from public.get_washroom_board(pg_temp.id('wash')) where machine_id = pg_temp.id('machine')$$),
  'e9000000-0000-0000-0000-000000000002/2', 'a known NEXT still shows its loads left');
select is(pg_temp.run_as('ownerB', $$select * from public.get_queue(pg_temp.id('wash'))$$), 'NOT_AUTHORIZED',
  'another tenant still cannot read the queue');

select * from finish();
rollback;
