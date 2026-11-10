-- Owner decision 2026-11-01: production day runs from plants.production_day_start to the same time next day,
-- plant-local; 10:00 → 10:00 since owner 2026-11-10 (was 12:00; 20261110105126).
-- shift_instances.production_date (trigger-set), app.production_date(), off-shift dating in the views,
-- DST, and "a setting change re-dates only instances that have not started yet".
-- Fixture week: Mon 2026-11-02 … Sun 2026-11-08 (America/New_York, EST).
begin;
\ir _fixtures.psql
select plan(30);

-- ── Schema ───────────────────────────────────────────────────────────────
select col_default_is('public', 'plants', 'production_day_start', '10:00:00'::time, 'production_day_start defaults to 10:00 (owner 2026-11-10)');
select col_not_null('public', 'plants', 'production_day_start', 'production_day_start is not null');
select col_not_null('public', 'shift_instances', 'production_date', 'shift_instances.production_date is not null');
select has_index('public', 'shift_instances', 'shift_instances_production_day_idx', array['plant_id', 'production_date', 'area_id'],
  'index (plant_id, production_date, area_id)');
select throws_ok($$update public.plants set production_day_start = '12:00:30' where id = pg_temp.id('plantA')$$,
  '23514', null, 'CHECK: production_day_start in whole minutes');
select is((select production_day_start from public.plants where id = pg_temp.id('plantA')), '10:00'::time, 'fixture plant uses 10:00');

-- ── The formula ──────────────────────────────────────────────────────────
select is(array[app.production_date(pg_temp.ny('2026-11-03 11:59'), 'America/New_York', '12:00'),
                app.production_date(pg_temp.ny('2026-11-03 12:00'), 'America/New_York', '12:00'),
                app.production_date(pg_temp.ny('2026-11-03 00:00'), 'America/New_York', '12:00')],
  array['2026-11-02', '2026-11-03', '2026-11-02']::date[], 'app.production_date: 11:59 → previous day; 12:00 → same day; midnight → previous day');

-- ── Owner examples (Monday's production day) ─────────────────────────────
select is(array[(select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('wash'), 'Evening', '2026-11-02')),
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('wash'), 'Night',   '2026-11-03')),
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('fin'),  'Evening', '2026-11-02')),
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('fin'),  'Night',   '2026-11-03')),
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('fin'),  'Day',     '2026-11-03'))],
  array['2026-11-02', '2026-11-02', '2026-11-02', '2026-11-02', '2026-11-03']::date[],
  'with 10:00: washroom Evening Mon 14–24 + Night Tue 00–12 and finishing Evening Mon 16–24 + Night Tue 00–10 → Monday; finishing Day Tue 10–16 → Tuesday (its own date)');
select is((select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('wash'), 'Evening', '2026-11-03')),
  '2026-11-03'::date, 'washroom Tue 14:00 starts Tuesday''s production day');
select is((select business_date from public.shift_instances where id = pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03')),
  '2026-11-03'::date, 'business_date keeps its meaning (local start date)');
-- Thursday variants: washroom Evening 15:00, finishing Evening 17:00, finishing Night 00–05; no Thu Day.
select is(array[(select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('wash'), 'Evening', '2026-11-05')),
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('fin'),  'Evening', '2026-11-05')),
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('fin'),  'Night',   '2026-11-05'))],
  array['2026-11-05', '2026-11-05', '2026-11-04']::date[],
  'Thursday: washroom Evening 15:00 and finishing Evening 17:00 → Thursday; finishing Night Thu 00–05 → Wednesday');
select is(array[(select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-06')),
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('fin'),  'Night', '2026-11-06')),
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('fin'),  'Day',   '2026-11-06'))],
  array['2026-11-05', '2026-11-05', '2026-11-06']::date[], 'Friday Nights close Thursday''s production day; Friday Day 10:00 opens Friday''s');
select is((select count(*)::int from public.shift_instances where plant_id = pg_temp.id('plantA') and production_date = '2026-11-02'),
  4, 'Monday''s production day has exactly the 4 Monday instances above');

-- ── Off-shift rows: 09:59 vs 10:01 (Sunday: plant closed) ────────────────
insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, load_count, source, entered_by, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), pg_temp.ny('2026-11-08 09:59'), 1, 'manual', pg_temp.id('lead'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gMat'),    pg_temp.ny('2026-11-08 10:01'), 1, 'manual', pg_temp.id('lead'), gen_random_uuid());
insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, occurred_at, entered_by, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 10, pg_temp.ny('2026-11-08 09:59'), pg_temp.id('manager'), gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'),    10, pg_temp.ny('2026-11-08 10:01'), pg_temp.id('manager'), gen_random_uuid());
select is(array[(select production_date from public.washroom_by_shift where shift_instance_id is null and wash_group_id = pg_temp.id('gNapkin')),
                (select production_date from public.washroom_by_shift where shift_instance_id is null and wash_group_id = pg_temp.id('gMat'))],
  array['2026-11-07', '2026-11-08']::date[], 'off-shift wash at 09:59 → previous production day, 10:01 → same day');
select is(array[(select production_date from public.finished_by_shift where shift_instance_id is null and item_type_id = pg_temp.id('napkin')),
                (select production_date from public.finished_by_shift where shift_instance_id is null and item_type_id = pg_temp.id('mat'))],
  array['2026-11-07', '2026-11-08']::date[], 'off-shift finished goods at 09:59 / 10:01 likewise');
select is((select array[loads_run, pieces_finished] from public.daily_reconciliation
            where production_date = '2026-11-07' and wash_group_id = pg_temp.id('gNapkin')),
  array[1, 10]::numeric[], 'daily_reconciliation puts both 09:59 rows on Saturday''s production day');

-- ── DST (plant B): 10:00 is local wall time on both transition days ──────
insert into public.shifts (org_id, plant_id, area_id, name, start_local, end_local, days_of_week) values
  (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), 'Late morning', '09:00', '09:59', '{0}'),
  (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), 'Noon',         '10:00', '11:00', '{0}');
select ok(app.generate_shift_instances(pg_temp.id('plantB'), 1, '2026-11-01') = 2
          and app.generate_shift_instances(pg_temp.id('plantB'), 1, '2026-03-08') = 2, 'Sunday instances on both DST days');
select is(array[pg_temp.si(pg_temp.id('washB'), 'Late morning', '2026-11-01') is not null,
                (select production_date = '2026-10-31' from public.shift_instances where id = pg_temp.si(pg_temp.id('washB'), 'Late morning', '2026-11-01')),
                (select production_date = '2026-11-01' from public.shift_instances where id = pg_temp.si(pg_temp.id('washB'), 'Noon', '2026-11-01'))],
  array[true, true, true], 'fall-back day (2026-11-01, EST): 09:00 → Saturday, 10:00 → Sunday');
select is(array[(select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('washB'), 'Late morning', '2026-03-08')),
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('washB'), 'Noon', '2026-03-08'))],
  array['2026-03-07', '2026-03-08']::date[], 'spring-forward day (2026-03-08, EDT): 09:00 → Saturday, 10:00 → Sunday');

-- ── Shift edits re-date the future instance (trigger on starts_at) ───────
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week) values
  ('90000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Brunch', '09:00', '09:30', '{2}');
select lives_ok($$select app.generate_shift_instances(pg_temp.id('plantA'), 2, '2030-01-07')$$, 'future Mon–Tue generated');
update public.shifts set start_local = '10:30', end_local = '11:00' where id = '90000000-0000-0000-0000-0000000000d1';
select lives_ok($$select app.generate_shift_instances(pg_temp.id('plantA'), 2, '2030-01-07')$$, 'regenerated after the edit');
select is((select production_date from public.shift_instances where shift_id = '90000000-0000-0000-0000-0000000000d1' and business_date = '2030-01-08'),
  '2030-01-08'::date, 'Tue 09:00 → Monday became Tue 10:30 → Tuesday when the shift moved');

-- ── Changing production_day_start: future instances only ─────────────────
select lives_ok($$select app.generate_shift_instances(pg_temp.id('plantA'), 2, '2020-01-06')$$, 'past Mon–Tue generated');
select is(array[pg_temp.run_as('manager', $$update public.plants set production_day_start = '15:00' where id = pg_temp.id('plantA')$$),
                pg_temp.run_as('owner',   $$update public.plants set production_day_start = '15:00' where id = pg_temp.id('plantA')$$)],
  '{0,1}', 'only the owner changes production_day_start');
select is(array[(select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('wash'), 'Evening', '2020-01-06')),
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('wash'), 'Evening', '2030-01-07'))],
  array['2020-01-06', '2030-01-06']::date[],
  'with 15:00, Mon 14:00 belongs to Sunday: the future instance is re-dated, the past one keeps its date');
select is((select count(*)::int from public.audit_log where action = 'shift_instances.update'
            and entity_id = pg_temp.si(pg_temp.id('wash'), 'Evening', '2030-01-07')
            and before ->> 'production_date' = '2030-01-07' and after ->> 'production_date' = '2030-01-06'),
  1, 're-dating is audited');

-- ── Owner 2026-11-10: 12:00 → 10:00 (the data migration's statement) ─────
select is(pg_temp.run_as('owner', $$update public.plants set production_day_start = '12:00' where id = pg_temp.id('plantA')$$), '1',
  'plant A back on the old 12:00');
select is(array[(select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('fin'), 'Day', '2030-01-08')),
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03'))],
  array['2030-01-07', '2026-11-03']::date[], 'with 12:00 the future Tue Day 10:00 is Monday''s; the started 2026-11-03 Day keeps its date');
update public.plants set production_day_start = '10:00' where production_day_start = '12:00';
select is(array[(select production_day_start from public.plants where id = pg_temp.id('plantA'))::text,
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('fin'), 'Day', '2030-01-08'))::text,
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('wash'), 'Night', '2030-01-08'))::text,
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('wash'), 'Evening', '2030-01-08'))::text,
                (select production_date from public.shift_instances where id = pg_temp.si(pg_temp.id('wash'), 'Evening', '2020-01-06'))::text],
  array['10:00:00', '2030-01-08', '2030-01-07', '2030-01-08', '2020-01-06'],
  'the migration''s update fires the re-date trigger: future finishing Tue 10:00 Day → Tuesday, washroom Tue 00:00 Night → Monday, Tue 14:00 Evening → Tuesday; started instances keep their date');
select is((select count(*)::int from public.audit_log where action = 'shift_instances.update'
            and entity_id = pg_temp.si(pg_temp.id('fin'), 'Day', '2030-01-08')
            and before ->> 'production_date' = '2030-01-07' and after ->> 'production_date' = '2030-01-08'),
  1, 'the 10:00 re-date is audited');

select * from finish();
rollback;
