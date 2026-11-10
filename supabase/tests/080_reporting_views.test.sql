-- §4.6 views: current_soil_estimates, queue_board, washroom_by_shift, finished_by_shift, daily_reconciliation.
-- security_invoker: the caller's RLS applies (cross-tenant, display limits). Conversions via app.to_loads.
-- Day grouping is the PRODUCTION DAY (12:00 → 12:00 local, owner 2026-11-01): Monday 2026-11-02's
-- production day = washroom Mon Evening + Tue Night, finishing Mon Evening + Tue Night + Tue Day.
-- Washroom loads: loads_run (raw) and standard_loads (× machine load_factor; Washer 6 = 1.19 here).
begin;
\ir _fixtures.psql
-- These report-arithmetic tests were written for the 12:00 production day (owner 2026-11-01). The day-start
-- rule itself (10:00 since owner 2026-11-10) is tested in 032; pin plant A to 12:00 and re-date its fixture instances.
update public.plants set production_day_start = '12:00' where id = pg_temp.id('plantA');
update public.shift_instances set production_date = app.production_date(starts_at, 'America/New_York', '12:00') where plant_id = pg_temp.id('plantA');
select plan(38);

insert into public.entry_staff (id, org_id, plant_id, display_name) values
  ('b0000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Ana');

-- Estimates: Napkin fixed dates (production-day bounds Mon 14:00 → Tue 16:00); Mat/Towel relative to
-- now() (freshness). The 17:00 estimate is after Monday's last shift end, so it is not est_loads_end.
insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, entered_at, client_id, staff_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 5, 'load',   pg_temp.id('manager'), pg_temp.ny('2026-11-02 13:00'), gen_random_uuid(), null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 8, 'load',   pg_temp.id('manager'), pg_temp.ny('2026-11-03 15:00'), gen_random_uuid(), null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 9, 'load',   pg_temp.id('manager'), pg_temp.ny('2026-11-03 17:00'), gen_random_uuid(), null),
  -- Sunday 2026-11-08's production day has no instances: bounds Sun 12:00 → Mon 12:00 (local).
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 10, 'load',  pg_temp.id('manager'), pg_temp.ny('2026-11-09 11:00'), gen_random_uuid(), null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 11, 'load',  pg_temp.id('manager'), pg_temp.ny('2026-11-09 13:00'), gen_random_uuid(), null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'),    2, 'load',   pg_temp.id('manager'), now() - interval '3 hours', gen_random_uuid(),
   'b0000000-0000-0000-0000-0000000000a1'),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gTowel'),  6, 'basket', pg_temp.id('manager'), now() - interval '5 hours', gen_random_uuid(), null),
  (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('groupB'),  1, 'load',   pg_temp.id('ownerB'),  now(), gen_random_uuid(), null);

-- Washer 6 (factor 1.19) next to fixture Washer 1 (default 1.00).
insert into public.machines (id, org_id, plant_id, area_id, name, kind, load_factor) values
  ('60000000-0000-0000-0000-0000000000a6', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 6', 'washer', 1.19);

-- Washroom: Napkin Tue Night 3 loads on Washer 1 + 2 loads on Washer 6; Mat 1 load Tue Evening (no machine);
-- Napkin 2 loads off-shift Sun 23:30 local (= Mon 04:30 UTC).
insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, machine_id, started_at, load_count, source, entered_by, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), pg_temp.id('machine'), pg_temp.ny('2026-11-03 01:00'), 3, 'manual', pg_temp.id('lead'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), '60000000-0000-0000-0000-0000000000a6', pg_temp.ny('2026-11-03 02:00'), 2, 'manual', pg_temp.id('lead'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gMat'),    null, pg_temp.ny('2026-11-03 15:00'), 1, 'manual', pg_temp.id('lead'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), null, pg_temp.ny('2026-11-08 23:30'), 2, 'manual', pg_temp.id('lead'), gen_random_uuid()),
  (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), pg_temp.id('groupB'), null, pg_temp.ny('2026-11-03 01:00'), 9, 'manual', pg_temp.id('ownerB'), gen_random_uuid());

-- Finishing: Napkin 734 (Tue Day) + 266 (Mon Evening) = 1000 on Monday's production day; a voided 500
-- is excluded; Mat 25 (Wed Day → Tuesday's production day).
insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, packs, loose_pieces, occurred_at, entered_by, client_id, voided_at, void_reason) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 7, 34,  pg_temp.ny('2026-11-03 11:30'), pg_temp.id('manager'), gen_random_uuid(), null, null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 0, 266, pg_temp.ny('2026-11-02 20:00'), pg_temp.id('manager'), gen_random_uuid(), null, null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 5, 0,   pg_temp.ny('2026-11-02 20:30'), pg_temp.id('manager'), gen_random_uuid(), now(), 'dup'),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'),    0, 25,  pg_temp.ny('2026-11-04 12:00'), pg_temp.id('manager'), gen_random_uuid(), null, null);

insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position, created_by, status, started_at, completed_at, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), pg_temp.id('napkin'), 4,  'load',  1, pg_temp.id('manager'), 'queued', null, null, gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'),  pg_temp.id('gMat'), pg_temp.id('mat'),    10, 'piece', 1, pg_temp.id('manager'), 'in_progress', now(), null, gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gTowel'), pg_temp.id('towel'),  2,  'load',  2, pg_temp.id('manager'), 'done', now(), now(), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gMat'), pg_temp.id('mat'),    2,  'load',  3, pg_temp.id('manager'), 'cancelled', null, null, gen_random_uuid());

-- current_soil_estimates
select is(pg_temp.reads($$select 1 from public.current_soil_estimates where plant_id = pg_temp.id('plantA')$$), '{3,3,3,3,3,0,0,42501}',
  'current_soil_estimates: one row per wash group; display reads estimates; no cross-tenant rows');
select is((select array[qty, qty_loads] from public.current_soil_estimates where wash_group_id = pg_temp.id('gNapkin')), array[11, 11]::numeric[],
  'latest estimate wins; loads = qty');
select is((select array[wash_group_name, wash_group_name_i18n ->> 'es'] from public.current_soil_estimates where wash_group_id = pg_temp.id('gNapkin')),
  array['Napkins', 'Servilletas'], 'current_soil_estimates carries the wash group names');
select is((select array[qty_loads::text, has_conversion::text, freshness] from public.current_soil_estimates where wash_group_id = pg_temp.id('gTowel')),
  array['3.00000', 'true', 'red'], 'baskets converted via the group''s loads_per_basket; 5 h old → red');
select is((select array[freshness, age_minutes::text] from public.current_soil_estimates where wash_group_id = pg_temp.id('gMat')),
  array['amber', '180'], '3 h old → amber; age in minutes');
select is((select coalesce(array_agg(attname::text), '{}') from pg_attribute
            where attrelid = 'public.current_soil_estimates'::regclass and attnum > 0
              and attname in ('entered_by', 'staff_id', 'entered_by_name')),
  '{}'::text[], 'owner 2026-11-04: current_soil_estimates names nobody (no entered_by, staff_id, entered_by_name)');
select is((select coalesce(array_agg(c.relname || '.' || a.attname order by 1), '{}') from pg_class c
             join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
            where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
              and (a.attname ~ '(^|_)(entered|created|updated|voided)_by' or a.attname in ('staff_id', 'entered_by_name', 'user_id', 'actor_user_id'))),
  '{}'::text[], 'no public view exposes who entered, created, updated or voided a row');

-- queue_board
select is(pg_temp.reads($$select 1 from public.queue_board where plant_id = pg_temp.id('plantA')$$), '{2,2,2,2,1,0,0,42501}',
  'queue_board: open items only; display sees its own area');
select is((select array[wash_group_name, wash_group_name_i18n ->> 'es', item_name, item_name_i18n ->> 'es', qty_loads::text, approximate::text]
             from public.queue_board where area_id = pg_temp.id('wash')),
  array['Napkins', 'Servilletas', 'Napkin', 'Servilleta', '4.00', 'false'], 'queue_board carries group and item names in all languages and load equivalent');
select is((select array[coalesce(qty_loads::text, 'null'), approximate::text] from public.queue_board where area_id = pg_temp.id('fin')),
  array['null', 'true'], 'pieces without pieces_per_load → null loads, flagged approximate');

-- washroom_by_shift
select is((select array[loads_run::text, standard_loads::text, approximate::text, production_date::text] from public.washroom_by_shift
            where shift_instance_id = pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03') and wash_group_id = pg_temp.id('gNapkin')),
  array['5', '5.38', 'true', '2026-11-02'],
  'Tue Night: 5 loads run = 3 × 1.00 + 2 × 1.19 = 5.38 standard loads (approximate); Monday''s production day');
select is((select array[loads_run::text, standard_loads::text, approximate::text, production_date::text] from public.washroom_by_shift
            where shift_instance_id = pg_temp.si(pg_temp.id('wash'), 'Evening', '2026-11-03') and wash_group_id = pg_temp.id('gMat')),
  array['1', '1.00', 'false', '2026-11-03'], 'no machine → factor 1, not approximate; Tue Evening starts Tuesday''s production day');
select is((select array[production_date::text, loads_run::text] from public.washroom_by_shift where shift_instance_id is null and plant_id = pg_temp.id('plantA')),
  array['2026-11-08', '2'], 'off-shift load (Sun 23:30 local) dated by its production day, in plant time (not UTC)');
select is(pg_temp.reads($$select 1 from public.washroom_by_shift$$), '{42501,42501,42501,42501,42501,42501,42501,42501}', 'washroom_by_shift: no client reads since 2026-11-05 (owner RPCs only)');

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
select is(pg_temp.reads($$select 1 from public.finished_by_shift where plant_id = pg_temp.id('plantA')$$), '{42501,42501,42501,42501,42501,42501,42501,42501}',
  'finished_by_shift: no client reads since 2026-11-05 (owner RPCs only)');

-- daily_reconciliation (production days)
select is((select array[loads_run, standard_loads, pieces_finished, pieces_without_conversion, loads_finished_approx, clean_backlog_loads_approx]
             from public.daily_reconciliation where production_date = '2026-11-02' and wash_group_id = pg_temp.id('gNapkin')),
  array[5, 5.38, 1000, 0, 2, 3.38]::numeric[],
  'napkin Monday: 5 loads run = 5.38 standard; 1000 pieces ≈ 2 loads finished; backlog uses standard loads (≈ 3.38)');
select is((select approximate from public.daily_reconciliation where production_date = '2026-11-02' and wash_group_id = pg_temp.id('gNapkin')),
  true, 'reconciliation is flagged approximate');
select is((select count(*)::int from public.daily_reconciliation where production_date = '2026-11-03' and wash_group_id = pg_temp.id('gNapkin')),
  0, 'Tue Night washing and Tue Day finishing do not create a Tuesday napkin row');
select is((select array[est_loads_start, est_loads_end] from public.daily_reconciliation
            where production_date = '2026-11-02' and wash_group_id = pg_temp.id('gNapkin')),
  array[5, 8]::numeric[], 'estimates at the production day''s first shift start (Mon 14:00) and last shift end (Tue 16:00)');
select is((select array[loads_run::text, standard_loads::text, pieces_finished::text, coalesce(loads_finished_approx::text, 'null'),
                         coalesce(clean_backlog_loads_approx::text, 'null'), finished_incomplete::text, pieces_without_conversion::text]
             from public.daily_reconciliation where production_date = '2026-11-03' and wash_group_id = pg_temp.id('gMat')),
  array['1', '1.00', '25', 'null', 'null', 'true', '25'], 'no conversion → loads and pieces side by side, flagged incomplete');
select is((select array[loads_run, standard_loads, pieces_finished] from public.daily_reconciliation
            where production_date = '2026-11-08' and wash_group_id = pg_temp.id('gNapkin')),
  array[2, 2, 0]::numeric[], 'off-shift loads still count in the production-day totals');
select is((select array[est_loads_start::text, est_loads_end::text] from public.daily_reconciliation
            where production_date = '2026-11-08' and wash_group_id = pg_temp.id('gNapkin')),
  array['9.00', '10.00'], 'a day without instances uses the 12:00 → 12:00 bounds (Mon 11:00 counts, Mon 13:00 does not)');
select is(pg_temp.reads($$select 1 from public.daily_reconciliation where plant_id = pg_temp.id('plantA')$$), '{42501,42501,42501,42501,42501,42501,42501,42501}',
  'daily_reconciliation: no client reads since 2026-11-05 (owner RPCs only)');
select is(pg_temp.run_as('anon', $$select 1 from public.daily_reconciliation$$, true), '42501', 'anon cannot read report views');

-- ── Wash-group reconciliation: several items sum into one group (owner 2026-11-01) ──
-- Black mats: 3×5 at 16/load, 4×6 at 12/load, 5×7 with no factor yet.
insert into public.wash_groups (id, org_id, plant_id, name) values
  ('71000000-0000-0000-0000-0000000000a9', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Black mats');
insert into public.item_types (id, org_id, plant_id, wash_group_id, name, category, count_mode, pieces_per_load, pieces_per_load_source) values
  ('70000000-0000-0000-0000-0000000000a7', pg_temp.id('orgA'), pg_temp.id('plantA'), '71000000-0000-0000-0000-0000000000a9', 'Black mat 3×5', 'mat', 'unit', 16, 'counted'),
  ('70000000-0000-0000-0000-0000000000a8', pg_temp.id('orgA'), pg_temp.id('plantA'), '71000000-0000-0000-0000-0000000000a9', 'Black mat 4×6', 'mat', 'unit', 12, 'counted'),
  ('70000000-0000-0000-0000-0000000000a9', pg_temp.id('orgA'), pg_temp.id('plantA'), '71000000-0000-0000-0000-0000000000a9', 'Black mat 5×7', 'mat', 'unit', null, null);
-- Thursday 2026-11-05: 1 load washed (Thu Evening); 8 × 3×5 + 6 × 4×6 finished (Thu Evening).
-- Friday 2026-11-06: 16 × 3×5 + 3 × 5×7 finished (the 5×7 has no pieces_per_load).
insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, machine_id, started_at, load_count, source, entered_by, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), '71000000-0000-0000-0000-0000000000a9', pg_temp.id('machine'), pg_temp.ny('2026-11-05 16:00'), 1, 'manual', pg_temp.id('lead'), gen_random_uuid());
insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, occurred_at, entered_by, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), '70000000-0000-0000-0000-0000000000a7', 8,  pg_temp.ny('2026-11-05 18:00'), pg_temp.id('manager'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), '70000000-0000-0000-0000-0000000000a8', 6,  pg_temp.ny('2026-11-05 19:00'), pg_temp.id('manager'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), '70000000-0000-0000-0000-0000000000a7', 16, pg_temp.ny('2026-11-06 18:00'), pg_temp.id('manager'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), '70000000-0000-0000-0000-0000000000a9', 3,  pg_temp.ny('2026-11-06 19:00'), pg_temp.id('manager'), gen_random_uuid());

select is((select array[loads_run, standard_loads, pieces_finished, items_finished, loads_finished_approx, clean_backlog_loads_approx]
             from public.daily_reconciliation where production_date = '2026-11-05' and wash_group_id = '71000000-0000-0000-0000-0000000000a9'),
  array[1, 1, 14, 2, 1.0, 0]::numeric[],
  'one group row: 8 × 3×5 (16/load) + 6 × 4×6 (12/load) = 0.5 + 0.5 = 1.0 finished load vs 1 load washed');
select is((select array[finished_incomplete::text, pieces_without_conversion::text, wash_group_name] from public.daily_reconciliation
            where production_date = '2026-11-05' and wash_group_id = '71000000-0000-0000-0000-0000000000a9'),
  array['false', '0', 'Black mats'], 'every finished item converts → complete');
select is((select array[pieces_finished::text, pieces_without_conversion::text, finished_incomplete::text,
                        coalesce(loads_finished_approx::text, 'null'), coalesce(clean_backlog_loads_approx::text, 'null'),
                        loads_finished_partial_approx::text, loads_run::text]
             from public.daily_reconciliation where production_date = '2026-11-06' and wash_group_id = '71000000-0000-0000-0000-0000000000a9'),
  array['19', '3', 'true', 'null', 'null', '1.00000000000000000000', '0'],
  'a finished item without pieces_per_load never undercounts silently: loads null, flagged, 3 pieces unconverted, partial ≥ 1.0');
select is((select count(*)::int from public.daily_reconciliation where wash_group_id = '71000000-0000-0000-0000-0000000000a9'), 2,
  'reconciliation is one row per production day per wash group (not per item)');
select is((select array_agg(wash_group_id::text order by item_type_id) from public.finished_by_shift
            where item_type_id in ('70000000-0000-0000-0000-0000000000a7', '70000000-0000-0000-0000-0000000000a8')
              and production_date = '2026-11-05'),
  array['71000000-0000-0000-0000-0000000000a9', '71000000-0000-0000-0000-0000000000a9'], 'finished_by_shift stays per item and names the item''s group');

-- ── Architect N1: history is snapshotted, so catalog / machine edits never rewrite past reports ──
-- Move Black mat 4×6 to the Mats group: Thursday's Black mats row is unchanged and Mats gains nothing.
update public.item_types set wash_group_id = pg_temp.id('gMat') where id = '70000000-0000-0000-0000-0000000000a8';
select is((select array[pieces_finished, items_finished, loads_finished_approx] from public.daily_reconciliation
            where production_date = '2026-11-05' and wash_group_id = '71000000-0000-0000-0000-0000000000a9'),
  array[14, 2, 1.0]::numeric[], 'moving an item to another group leaves the past reconciliation unchanged');
select is((select count(*)::int from public.daily_reconciliation where production_date = '2026-11-05' and wash_group_id = pg_temp.id('gMat')),
  0, 'the item''s new group does not inherit its past entries');
-- Change Washer 6's load_factor: past standard_loads stay at 5.38.
update public.machines set load_factor = 2.00 where id = '60000000-0000-0000-0000-0000000000a6';
select is((select array[(select standard_loads from public.washroom_by_shift
                          where shift_instance_id = pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03') and wash_group_id = pg_temp.id('gNapkin')),
                        (select standard_loads from public.daily_reconciliation
                          where production_date = '2026-11-02' and wash_group_id = pg_temp.id('gNapkin'))]),
  array[5.38, 5.38]::numeric[], 'changing a machine''s load_factor leaves past standard_loads unchanged');

-- Security: anon has no SELECT on any of the recreated report views.
select is((select array_agg(has_table_privilege('anon', v, 'select') order by v)
             from unnest(array['public.current_soil_estimates', 'public.queue_board', 'public.washroom_by_shift',
                               'public.finished_by_shift', 'public.daily_reconciliation']) v),
  array[false, false, false, false, false], 'anon cannot SELECT any recreated view');

select * from finish();
rollback;
