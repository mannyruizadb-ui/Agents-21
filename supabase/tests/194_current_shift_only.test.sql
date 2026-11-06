-- Owner 2026-11-05: managers (and leads, viewers) see only the CURRENT shift's totals; the owner sees
-- every shift. get_shift_report, the history views and the raw washer_cycles / finished_goods_entries.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(9);

-- A shift running now in the spare area, one that ended an hour ago, and one later today.
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week, active) values
  ('90000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Now', '00:00', '01:00', '{0}', false),
  ('90000000-0000-0000-0000-0000000000d2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Past', '00:00', '01:00', '{0}', false),
  ('90000000-0000-0000-0000-0000000000d3', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Later', '00:00', '01:00', '{0}', false);
insert into public.shift_instances (id, org_id, plant_id, area_id, shift_id, business_date, starts_at, ends_at) values
  ('91000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '90000000-0000-0000-0000-0000000000d1', '2000-01-01', now() - interval '1 hour', now() + interval '1 hour'),
  ('91000000-0000-0000-0000-0000000000d2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '90000000-0000-0000-0000-0000000000d2', '2000-01-01', now() - interval '3 hours', now() - interval '1 hour'),
  ('91000000-0000-0000-0000-0000000000d3', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '90000000-0000-0000-0000-0000000000d3', '2000-01-01', now() + interval '1 hour', now() + interval '3 hours');

select is(pg_temp.writes($$select public.get_shift_report('91000000-0000-0000-0000-0000000000d1')$$),
  '{1,1,1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'the CURRENT shift: owner, manager, lead, viewer (display, other tenant denied)');
select is(pg_temp.writes($$select public.get_shift_report('91000000-0000-0000-0000-0000000000d2')$$),
  '{1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'the previous shift: owner only');
select is(pg_temp.writes($$select public.get_shift_report('91000000-0000-0000-0000-0000000000d3')$$),
  '{1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'a later shift: owner only');
update public.shift_instances set skipped_at = now() where id = '91000000-0000-0000-0000-0000000000d1';
select is(pg_temp.run_as('manager', $$select public.get_shift_report('91000000-0000-0000-0000-0000000000d1')$$), 'NOT_AUTHORIZED',
  'a skipped instance is not "current"');
update public.shift_instances set skipped_at = null where id = '91000000-0000-0000-0000-0000000000d1';

-- Raw rows: finished goods in the spare area, one in the current shift, one in the previous shift.
insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, occurred_at, entered_by, client_id, shift_instance_id)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), pg_temp.id('mat'), 3, now() - interval '30 minutes', pg_temp.id('owner'), gen_random_uuid(), '91000000-0000-0000-0000-0000000000d1'),
       (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), pg_temp.id('mat'), 5, now() - interval '2 hours', pg_temp.id('owner'), gen_random_uuid(), '91000000-0000-0000-0000-0000000000d2');
select is(pg_temp.reads($$select 1 from public.finished_goods_entries where area_id = pg_temp.id('spare')$$),
  '{2,1,1,1,0,0,0,42501}', 'finished goods rows: the owner sees both shifts; manager/lead/viewer only the current one');
select is(pg_temp.val_as('manager', $$select sum(pieces)::text from public.finished_goods_entries where area_id = pg_temp.id('spare')$$), '3',
  'a manager''s totals are the current shift''s');

-- History views: no client grant (the owner reads them through RPCs).
select is(array[
  pg_temp.run_as('owner', $$select 1 from public.daily_reconciliation$$),
  pg_temp.run_as('owner', $$select 1 from public.washroom_by_shift$$),
  pg_temp.run_as('manager', $$select 1 from public.finished_by_shift$$)],
  '{42501,42501,42501}', 'daily_reconciliation, washroom_by_shift, finished_by_shift: no direct client reads');
select is(array[
  pg_temp.run_as('manager', $$select 1 from public.queue_board$$),
  pg_temp.run_as('manager', $$select 1 from public.current_soil_estimates$$)],
  '{0,0}', 'the manager screens'' views (queue_board, current_soil_estimates) still work');
select is(pg_temp.run_as('manager', $$select public.get_day_report(pg_temp.id('plantA'), current_date)$$), 'NOT_AUTHORIZED',
  'the day report stays owner-only');

select * from finish();
rollback;
