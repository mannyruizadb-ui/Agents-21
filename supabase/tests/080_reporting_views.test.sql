-- §4.6 views: current_soil_estimates, queue_board, washroom_by_shift, finished_by_shift, daily_reconciliation.
-- security_invoker: the caller's RLS applies (cross-tenant, display limits). Conversions via app.to_loads.
-- Day grouping is the PRODUCTION DAY (12:00 → 12:00 local, owner 2026-11-01): Monday 2026-11-02's
-- production day = washroom Mon Evening + Tue Night, finishing Mon Evening + Tue Night + Tue Day.
-- Washroom loads: loads_run (raw) and standard_loads (× machine load_factor; Washer 6 = 1.19 here).
begin;
\ir _fixtures.psql
select plan(28);

insert into public.entry_staff (id, org_id, plant_id, display_name) values
  ('b0000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Ana');

-- Estimates: Napkin fixed dates (production-day bounds Mon 14:00 → Tue 16:00); Mat/Towel relative to
-- now() (freshness). The 17:00 estimate is after Monday's last shift end, so it is not est_loads_end.
insert into public.soil_estimates (org_id, plant_id, item_type_id, qty, unit, entered_by, entered_at, client_id, staff_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 5, 'load',   pg_temp.id('manager'), pg_temp.ny('2026-11-02 13:00'), gen_random_uuid(), null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 8, 'load',   pg_temp.id('manager'), pg_temp.ny('2026-11-03 15:00'), gen_random_uuid(), null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 9, 'load',   pg_temp.id('manager'), pg_temp.ny('2026-11-03 17:00'), gen_random_uuid(), null),
  -- Sunday 2026-11-08's production day has no instances: bounds Sun 12:00 → Mon 12:00 (local).
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 10, 'load',  pg_temp.id('manager'), pg_temp.ny('2026-11-09 11:00'), gen_random_uuid(), null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('napkin'), 11, 'load',  pg_temp.id('manager'), pg_temp.ny('2026-11-09 13:00'), gen_random_uuid(), null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('mat'),    2, 'load',   pg_temp.id('manager'), now() - interval '3 hours', gen_random_uuid(),
   'b0000000-0000-0000-0000-0000000000a1'),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('towel'),  6, 'basket', pg_temp.id('manager'), now() - interval '5 hours', gen_random_uuid(), null),
  (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('itemB'),  1, 'load',   pg_temp.id('ownerB'),  now(), gen_random_uuid(), null);

-- Washer 6 (factor 1.19) next to fixture Washer 1 (default 1.00).
insert into public.machines (id, org_id, plant_id, area_id, name, kind, load_factor) values
  ('60000000-0000-0000-0000-0000000000a6', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 6', 'washer', 1.19);

-- Washroom: Napkin Tue Night 3 loads on Washer 1 + 2 loads on Washer 6; Mat 1 load Tue Evening (no machine);
-- Napkin 2 loads off-shift Sun 23:30 local (= Mon 04:30 UTC).
insert into public.washer_cycles (org_id, plant_id, area_id, item_type_id, machine_id, started_at, load_count, source, entered_by, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('napkin'), pg_temp.id('machine'), pg_temp.ny('2026-11-03 01:00'), 3, 'manual', pg_temp.id('lead'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('napkin'), '60000000-0000-0000-0000-0000000000a6', pg_temp.ny('2026-11-03 02:00'), 2, 'manual', pg_temp.id('lead'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('mat'),    null, pg_temp.ny('2026-11-03 15:00'), 1, 'manual', pg_temp.id('lead'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('napkin'), null, pg_temp.ny('2026-11-08 23:30'), 2, 'manual', pg_temp.id('lead'), gen_random_uuid()),
  (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), pg_temp.id('itemB'), null, pg_temp.ny('2026-11-03 01:00'), 9, 'manual', pg_temp.id('ownerB'), gen_random_uuid());

-- Finishing: Napkin 734 (Tue Day) + 266 (Mon Evening) = 1000 on Monday's production day; a voided 500
-- is excluded; Mat 25 (Wed Day → Tuesday's production day).
insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, packs, loose_pieces, occurred_at, entered_by, client_id, voided_at, void_reason) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 7, 34,  pg_temp.ny('2026-11-03 11:30'), pg_temp.id('manager'), gen_random_uuid(), null, null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 0, 266, pg_temp.ny('2026-11-02 20:00'), pg_temp.id('manager'), gen_random_uuid(), null, null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 5, 0,   pg_temp.ny('2026-11-02 20:30'), pg_temp.id('manager'), gen_random_uuid(), now(), 'dup'),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'),    0, 25,  pg_temp.ny('2026-11-04 12:00'), pg_temp.id('manager'), gen_random_uuid(), null, null);

insert into public.queue_items (org_id, plant_id, area_id, item_type_id, qty, unit, position, created_by, status, started_at, completed_at, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('napkin'), 4,  'load',  1, pg_temp.id('manager'), 'queued', null, null, gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'),  pg_temp.id('mat'),    10, 'piece', 1, pg_temp.id('manager'), 'in_progress', now(), null, gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('towel'),  2,  'load',  2, pg_temp.id('manager'), 'done', now(), now(), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('mat'),    2,  'load',  3, pg_temp.id('manager'), 'cancelled', null, null, gen_random_uuid());

-- current_soil_estimates
select is(pg_temp.reads($$select 1 from public.current_soil_estimates where plant_id = pg_temp.id('plantA')$$), '{3,3,3,3,3,0,0,42501}',
  'current_soil_estimates: one row per item; display reads estimates; no cross-tenant rows');
select is((select array[qty, qty_loads] from public.current_soil_estimates where item_type_id = pg_temp.id('napkin')), array[11, 11]::numeric[],
  'latest estimate wins; loads = qty');
select is((select array[qty_loads::text, has_conversion::text, freshness] from public.current_soil_estimates where item_type_id = pg_temp.id('towel')),
  array['3.0000000000000000', 'true', 'red'], 'baskets converted via baskets_per_load; 5 h old → red');
select is((select array[freshness, age_minutes::text] from public.current_soil_estimates where item_type_id = pg_temp.id('mat')),
  array['amber', '180'], '3 h old → amber; age in minutes');
select is(array[pg_temp.run_as('lead', $$select 1 from public.current_soil_estimates where entered_by_name = 'Ana'$$, true),
                pg_temp.run_as('viewer', $$select 1 from public.current_soil_estimates where item_type_id = pg_temp.id('mat') and entered_by_name is null$$, true)],
  '{1,1}', 'who entered is visible to entry-staff readers only');
select is(pg_temp.run_as('display', $$select 1 from public.current_soil_estimates where item_type_id = pg_temp.id('mat') and entered_by_name is null$$, true),
  '1', 'entered_by_name is null for a display');

-- queue_board
select is(pg_temp.reads($$select 1 from public.queue_board where plant_id = pg_temp.id('plantA')$$), '{2,2,2,2,1,0,0,42501}',
  'queue_board: open items only; display sees its own area');
select is((select array[item_name, item_name_i18n ->> 'es', qty_loads::text, approximate::text] from public.queue_board where area_id = pg_temp.id('wash')),
  array['Napkin', 'Servilleta', '4.00', 'false'], 'queue_board carries item names in all languages and load equivalent');
select is((select array[coalesce(qty_loads::text, 'null'), approximate::text] from public.queue_board where area_id = pg_temp.id('fin')),
  array['null', 'true'], 'pieces without pieces_per_load → null loads, flagged approximate');

-- washroom_by_shift
select is((select array[loads_run::text, standard_loads::text, approximate::text, production_date::text] from public.washroom_by_shift
            where shift_instance_id = pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03') and item_type_id = pg_temp.id('napkin')),
  array['5', '5.38', 'true', '2026-11-02'],
  'Tue Night: 5 loads run = 3 × 1.00 + 2 × 1.19 = 5.38 standard loads (approximate); Monday''s production day');
select is((select array[loads_run::text, standard_loads::text, approximate::text, production_date::text] from public.washroom_by_shift
            where shift_instance_id = pg_temp.si(pg_temp.id('wash'), 'Evening', '2026-11-03') and item_type_id = pg_temp.id('mat')),
  array['1', '1', 'false', '2026-11-03'], 'no machine → factor 1, not approximate; Tue Evening starts Tuesday''s production day');
select is((select array[production_date::text, loads_run::text] from public.washroom_by_shift where shift_instance_id is null and plant_id = pg_temp.id('plantA')),
  array['2026-11-08', '2'], 'off-shift load (Sun 23:30 local) dated by its production day, in plant time (not UTC)');
select is(pg_temp.reads($$select 1 from public.washroom_by_shift$$), '{3,3,3,3,0,0,1,42501}', 'washroom_by_shift respects RLS (display none; B sees only B)');

-- finished_by_shift
select is((select array[packs, loose_pieces, pieces] from public.finished_by_shift
            where shift_instance_id = pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03') and item_type_id = pg_temp.id('napkin')),
  array[7, 34, 734], 'finished goods per item per shift');
select is((select array[loads_approx::text, approximate::text, has_conversion::text] from public.finished_by_shift
            where shift_instance_id = pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03') and item_type_id = pg_temp.id('napkin')),
  array['1.4680000000000000', 'true', 'true'], 'pieces → loads via to_loads(piece), flagged approximate');
select is((select pieces from public.finished_by_shift
            where shift_instance_id = pg_temp.si(pg_temp.id('fin'), 'Evening', '2026-11-02') and item_type_id = pg_temp.id('napkin')),
  266, 'voided entries are excluded');
select is((select production_date from public.finished_by_shift
            where shift_instance_id = pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03') and item_type_id = pg_temp.id('napkin')),
  '2026-11-02'::date, 'finishing Tue Day 10–16 belongs to Monday''s production day');
select is((select array[coalesce(loads_approx::text, 'null'), has_conversion::text] from public.finished_by_shift where item_type_id = pg_temp.id('mat')),
  array['null', 'false'], 'no pieces_per_load → no conversion');
select is(pg_temp.reads($$select 1 from public.finished_by_shift where plant_id = pg_temp.id('plantA')$$), '{3,3,3,3,0,0,0,42501}',
  'finished_by_shift respects RLS (display none)');

-- daily_reconciliation (production days)
select is((select array[loads_run, standard_loads, pieces_finished, pieces_per_load, loads_finished_approx, clean_backlog_loads_approx]
             from public.daily_reconciliation where production_date = '2026-11-02' and item_type_id = pg_temp.id('napkin')),
  array[5, 5.38, 1000, 500, 2, 3.38]::numeric[],
  'napkin Monday: 5 loads run = 5.38 standard; 1000 pieces ≈ 2 loads finished; backlog uses standard loads (≈ 3.38)');
select is((select approximate from public.daily_reconciliation where production_date = '2026-11-02' and item_type_id = pg_temp.id('napkin')),
  true, 'reconciliation is flagged approximate');
select is((select count(*)::int from public.daily_reconciliation where production_date = '2026-11-03' and item_type_id = pg_temp.id('napkin')),
  0, 'Tue Night washing and Tue Day finishing do not create a Tuesday napkin row');
select is((select array[est_loads_start, est_loads_end] from public.daily_reconciliation
            where production_date = '2026-11-02' and item_type_id = pg_temp.id('napkin')),
  array[5, 8]::numeric[], 'estimates at the production day''s first shift start (Mon 14:00) and last shift end (Tue 16:00)');
select is((select array[loads_run::text, standard_loads::text, pieces_finished::text, coalesce(loads_finished_approx::text, 'null'), has_conversion::text]
             from public.daily_reconciliation where production_date = '2026-11-03' and item_type_id = pg_temp.id('mat')),
  array['1', '1', '25', 'null', 'false'], 'no conversion → loads and pieces side by side, has_conversion false');
select is((select array[loads_run, standard_loads, pieces_finished] from public.daily_reconciliation
            where production_date = '2026-11-08' and item_type_id = pg_temp.id('napkin')),
  array[2, 2, 0]::numeric[], 'off-shift loads still count in the production-day totals');
select is((select array[est_loads_start::text, est_loads_end::text] from public.daily_reconciliation
            where production_date = '2026-11-08' and item_type_id = pg_temp.id('napkin')),
  array['9.00', '10.00'], 'a day without instances uses the 12:00 → 12:00 bounds (Mon 11:00 counts, Mon 13:00 does not)');
select is(pg_temp.reads($$select 1 from public.daily_reconciliation where plant_id = pg_temp.id('plantA')$$), '{3,3,3,3,0,0,0,42501}',
  'daily_reconciliation respects RLS (display none; no cross-tenant)');
select is(pg_temp.run_as('anon', $$select 1 from public.daily_reconciliation$$, true), '42501', 'anon cannot read report views');

select * from finish();
rollback;
