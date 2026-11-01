-- §4.6 views: current_soil_estimates, queue_board, washroom_by_shift, finished_by_shift, daily_reconciliation.
-- security_invoker: the caller's RLS applies (cross-tenant, display limits). Conversions via app.to_loads.
begin;
\ir _fixtures.psql
select plan(22);

insert into public.entry_staff (id, org_id, plant_id, display_name) values
  ('b0000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Ana');

-- Estimates: Napkin fixed dates (day boundaries); Mat/Towel relative to now() (freshness).
insert into public.soil_estimates (org_id, plant_id, item_type_id, qty, unit, entered_by, entered_at, client_id, staff_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 5, 'load',   pg_temp.id('manager'), pg_temp.ny('2026-11-02 22:00'), gen_random_uuid(), null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 8, 'load',   pg_temp.id('manager'), pg_temp.ny('2026-11-03 20:00'), gen_random_uuid(), null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('mat'),    2, 'load',   pg_temp.id('manager'), now() - interval '3 hours', gen_random_uuid(),
   'b0000000-0000-0000-0000-0000000000a1'),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('towel'),  6, 'basket', pg_temp.id('manager'), now() - interval '5 hours', gen_random_uuid(), null),
  (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('itemB'),  1, 'load',   pg_temp.id('ownerB'),  now(), gen_random_uuid(), null);

-- Washroom: Napkin 3 loads Tue Night; Mat 1 load Tue Evening; Napkin 2 loads off-shift Sun 23:30 local (= Mon 04:30 UTC).
insert into public.washer_cycles (org_id, plant_id, area_id, item_type_id, started_at, load_count, source, entered_by, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('napkin'), pg_temp.ny('2026-11-03 01:00'), 3, 'manual', pg_temp.id('lead'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('mat'),    pg_temp.ny('2026-11-03 15:00'), 1, 'manual', pg_temp.id('lead'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('napkin'), pg_temp.ny('2026-11-08 23:30'), 2, 'manual', pg_temp.id('lead'), gen_random_uuid()),
  (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), pg_temp.id('itemB'), pg_temp.ny('2026-11-03 01:00'), 9, 'manual', pg_temp.id('ownerB'), gen_random_uuid());

-- Finishing: Napkin 734 (Day) + 266 (Evening) = 1000; a voided 500 is excluded; Mat 25 (Day).
insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, packs, loose_pieces, occurred_at, entered_by, client_id, voided_at, void_reason) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 7, 34,  pg_temp.ny('2026-11-03 11:30'), pg_temp.id('manager'), gen_random_uuid(), null, null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 0, 266, pg_temp.ny('2026-11-03 20:00'), pg_temp.id('manager'), gen_random_uuid(), null, null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 5, 0,   pg_temp.ny('2026-11-03 20:30'), pg_temp.id('manager'), gen_random_uuid(), now(), 'dup'),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'),    0, 25,  pg_temp.ny('2026-11-03 12:00'), pg_temp.id('manager'), gen_random_uuid(), null, null);

insert into public.queue_items (org_id, plant_id, area_id, item_type_id, qty, unit, position, created_by, status, started_at, completed_at) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('napkin'), 4,  'load',  1, pg_temp.id('manager'), 'queued', null, null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'),  pg_temp.id('mat'),    10, 'piece', 1, pg_temp.id('manager'), 'in_progress', now(), null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('towel'),  2,  'load',  2, pg_temp.id('manager'), 'done', now(), now()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('mat'),    2,  'load',  3, pg_temp.id('manager'), 'cancelled', null, null);

-- current_soil_estimates
select is(pg_temp.reads($$select 1 from public.current_soil_estimates where plant_id = pg_temp.id('plantA')$$), '{3,3,3,3,3,0,0,42501}',
  'current_soil_estimates: one row per item; display reads estimates; no cross-tenant rows');
select is((select array[qty, qty_loads] from public.current_soil_estimates where item_type_id = pg_temp.id('napkin')), array[8, 8]::numeric[],
  'latest estimate wins; loads = qty');
select is((select array[qty_loads::text, has_conversion::text, freshness] from public.current_soil_estimates where item_type_id = pg_temp.id('towel')),
  array['3.0000000000000000', 'true', 'red'], 'baskets converted via baskets_per_load; 5 h old → red');
select is((select array[freshness, age_minutes::text] from public.current_soil_estimates where item_type_id = pg_temp.id('mat')),
  array['amber', '180'], '3 h old → amber; age in minutes');
select is(array[pg_temp.run_as('lead', $$select 1 from public.current_soil_estimates where entered_by_name = 'Ana'$$, true),
                pg_temp.run_as('viewer', $$select 1 from public.current_soil_estimates where item_type_id = pg_temp.id('mat') and entered_by_name is null$$, true)],
  '{1,1}', 'who entered is visible to entry-staff readers only');

-- queue_board
select is(pg_temp.reads($$select 1 from public.queue_board where plant_id = pg_temp.id('plantA')$$), '{2,2,2,2,1,0,0,42501}',
  'queue_board: open items only; display sees its own area');
select is((select array[item_name, item_name_i18n ->> 'es', qty_loads::text, approximate::text] from public.queue_board where area_id = pg_temp.id('wash')),
  array['Napkin', 'Servilleta', '4.00', 'false'], 'queue_board carries item names in all languages and load equivalent');
select is((select array[coalesce(qty_loads::text, 'null'), approximate::text] from public.queue_board where area_id = pg_temp.id('fin')),
  array['null', 'true'], 'pieces without pieces_per_load → null loads, flagged approximate');

-- washroom_by_shift
select is((select loads from public.washroom_by_shift where shift_instance_id = pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03')
            and item_type_id = pg_temp.id('napkin')), 3, 'loads per item per shift');
select is((select array[business_date::text, loads::text] from public.washroom_by_shift where shift_instance_id is null and plant_id = pg_temp.id('plantA')),
  array['2026-11-08', '2'], 'D9: off-shift load dated by the plant-local calendar day (not UTC)');
select is(pg_temp.reads($$select 1 from public.washroom_by_shift$$), '{3,3,3,3,0,0,1,42501}', 'washroom_by_shift respects RLS (display none; B sees only B)');

-- finished_by_shift
select is((select array[packs, loose_pieces, pieces] from public.finished_by_shift
            where shift_instance_id = pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03') and item_type_id = pg_temp.id('napkin')),
  array[7, 34, 734], 'finished goods per item per shift');
select is((select array[loads_approx::text, approximate::text, has_conversion::text] from public.finished_by_shift
            where shift_instance_id = pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03') and item_type_id = pg_temp.id('napkin')),
  array['1.4680000000000000', 'true', 'true'], 'pieces → loads via to_loads(piece), flagged approximate');
select is((select pieces from public.finished_by_shift
            where shift_instance_id = pg_temp.si(pg_temp.id('fin'), 'Evening', '2026-11-03') and item_type_id = pg_temp.id('napkin')),
  266, 'voided entries are excluded');
select is((select array[coalesce(loads_approx::text, 'null'), has_conversion::text] from public.finished_by_shift where item_type_id = pg_temp.id('mat')),
  array['null', 'false'], 'no pieces_per_load → no conversion');
select is(pg_temp.reads($$select 1 from public.finished_by_shift where plant_id = pg_temp.id('plantA')$$), '{3,3,3,3,0,0,0,42501}',
  'finished_by_shift respects RLS (display none)');

-- daily_reconciliation
select is((select array[loads_washed, pieces_finished, pieces_per_load, loads_finished_approx, clean_backlog_loads_approx]
             from public.daily_reconciliation where business_date = '2026-11-03' and item_type_id = pg_temp.id('napkin')),
  array[3, 1000, 500, 2, 1]::numeric[], 'napkin day: 3 loads washed, 1000 pieces ≈ 2 loads finished, ≈ 1 load backlog');
select is((select array[est_loads_start, est_loads_end] from public.daily_reconciliation
            where business_date = '2026-11-03' and item_type_id = pg_temp.id('napkin')),
  array[5, 8]::numeric[], 'estimates at the business day''s first shift start and last shift end');
select is((select array[loads_washed::text, pieces_finished::text, coalesce(loads_finished_approx::text, 'null'), has_conversion::text]
             from public.daily_reconciliation where business_date = '2026-11-03' and item_type_id = pg_temp.id('mat')),
  array['1', '25', 'null', 'false'], 'no conversion → loads and pieces side by side, has_conversion false');
select is((select array[loads_washed, pieces_finished] from public.daily_reconciliation
            where business_date = '2026-11-08' and item_type_id = pg_temp.id('napkin')),
  array[2, 0]::numeric[], 'off-shift loads still count in the day totals');
select is(pg_temp.reads($$select 1 from public.daily_reconciliation where plant_id = pg_temp.id('plantA')$$), '{3,3,3,3,0,0,0,42501}',
  'daily_reconciliation respects RLS (display none; no cross-tenant)');
select is(pg_temp.run_as('anon', $$select 1 from public.daily_reconciliation$$, true), '42501', 'anon cannot read report views');

select * from finish();
rollback;
