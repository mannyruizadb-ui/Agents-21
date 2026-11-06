-- Owner 2026-11-04 "no names anywhere" + security re-review note 4: who entered / created / updated /
-- voided an operational row is stored but not SELECTable by clients (column-level grants).
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(8);

select is((select coalesce(array_agg(t || '.' || c order by 1), '{}') from (values
             ('soil_estimates', 'entered_by'), ('soil_estimates', 'staff_id'),
             ('finished_goods_entries', 'entered_by'), ('finished_goods_entries', 'staff_id'), ('finished_goods_entries', 'voided_by'),
             ('washer_cycles', 'entered_by'), ('washer_cycles', 'staff_id'), ('washer_cycles', 'voided_by'),
             ('queue_items', 'created_by'), ('queue_items', 'updated_by'), ('queue_items', 'updated_by_staff_id'),
             ('machine_status_events', 'entered_by'), ('machine_status_events', 'reason'), ('machine_status_events', 'reason_code')) v(t, c)
            where has_column_privilege('authenticated', 'public.' || t, c, 'SELECT')),
  '{}'::text[], 'authenticated cannot SELECT any who-entered column (nor machine-down reasons)');
select is((select coalesce(array_agg(t order by 1), '{}') from unnest(array['soil_estimates', 'finished_goods_entries', 'washer_cycles', 'queue_items', 'machine_status_events']) t
            where has_any_column_privilege('anon', 'public.' || t, 'SELECT')
               or has_table_privilege('authenticated', 'public.' || t, 'MAINTAIN')),
  '{}'::text[], 'anon has nothing on these tables; authenticated has no MAINTAIN');
select is(pg_temp.writes($$select entered_by from public.soil_estimates$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'soil_estimates.entered_by: no role (owner included)');
select is(array[pg_temp.run_as('lead', $$select staff_id from public.finished_goods_entries$$),
                pg_temp.run_as('viewer', $$select entered_by from public.washer_cycles$$),
                pg_temp.run_as('manager', $$select created_by from public.queue_items$$),
                pg_temp.run_as('owner', $$select * from public.queue_items$$)],
  '{42501,42501,42501,42501}', 'other who-entered columns, and select * (clients must name columns)');

-- Normal reads still work: the board's columns, and every view (security_invoker) over these tables.
select is(pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 2, 'load', gen_random_uuid(), pg_temp.id('gMat'))$$), '1', 'a queue item');
select is(pg_temp.reads($$select id, status, qty, unit, is_rush, position, version, assigned_machine_id from public.queue_items where plant_id = pg_temp.id('plantA')$$),
  '{1,1,1,1,1,0,0,42501}', 'queue_items: the other columns stay readable under RLS');
select is(array[
  pg_temp.run_as('viewer', $$select * from public.queue_board$$, true),
  pg_temp.run_as('viewer', $$select * from public.current_soil_estimates$$, true),
  pg_temp.run_as('viewer', $$select * from public.washroom_by_shift$$, true),
  pg_temp.run_as('viewer', $$select * from public.finished_by_shift$$, true),
  pg_temp.run_as('viewer', $$select * from public.daily_reconciliation$$, true),
  pg_temp.run_as('display', $$select * from public.queue_board$$, true)],
  '{1,0,0,0,0,1}', 'every reporting view still works for readers (security_invoker over the column grants)');
select is(pg_temp.run_as('lead', $$select * from public.get_washroom_board(pg_temp.id('wash'))$$, true), '1',
  'definer RPCs are unaffected');

select * from finish();
rollback;
