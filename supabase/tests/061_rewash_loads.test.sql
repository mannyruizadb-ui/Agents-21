-- Owner decision 2026-11-02 (C): washer_cycles.is_rewash. A rewash is washer work on goods that were
-- already washed, so it never counts toward washed-vs-finished reconciliation.
-- One definition in both views: loads_run = all loads (rewash included); rewash_loads = rewash loads (raw);
-- standard_loads = Σ load_count × load_factor_used over NON-rewash cycles only.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
-- These report-arithmetic tests were written for the 12:00 production day (owner 2026-11-01). The day-start
-- rule itself (10:00 since owner 2026-11-10) is tested in 032; pin plant A to 12:00 and re-date its fixture instances.
update public.plants set production_day_start = '12:00' where id = pg_temp.id('plantA');
update public.shift_instances set production_date = app.production_date(starts_at, 'America/New_York', '12:00') where plant_id = pg_temp.id('plantA');
select plan(16);

-- Washer 6 (factor 1.19) next to fixture Washer 1 (1.00).
insert into public.machines (id, org_id, plant_id, area_id, name, kind, load_factor) values
  ('60000000-0000-0000-0000-0000000000a6', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 6', 'washer', 1.19);

-- ── Column and write rules ────────────────────────────────────────────────
select col_type_is('public', 'washer_cycles', 'is_rewash', 'boolean', 'washer_cycles.is_rewash is boolean');
select col_not_null('public', 'washer_cycles', 'is_rewash', 'is_rewash is not null');
select col_default_is('public', 'washer_cycles', 'is_rewash', 'false', 'is_rewash defaults to false');
select is(pg_temp.writes($$insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, load_count, source, entered_by, client_id, is_rewash)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gTowel'), pg_temp.ny('2026-11-10 01:00'), 1, 'manual', (select auth.uid()), gen_random_uuid(), true)$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'M2: no direct rewash insert for any role (start_washer_load copies the queue item''s flag)');
insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, load_count, source, entered_by, client_id, is_rewash)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gTowel'), pg_temp.ny('2026-11-10 01:00'), 1, 'manual', pg_temp.id('lead'), gen_random_uuid(), true);
select is(pg_temp.writes($$update public.washer_cycles set is_rewash = false where plant_id = pg_temp.id('plantA')$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'the rewash flag cannot be changed by any client after the fact (no UPDATE privilege)');
select throws_ok($$insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, started_at, source, client_id, is_rewash)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), now(), 'manual', gen_random_uuid(), null)$$,
  '23502', null, 'is_rewash cannot be null');

-- ── Data: production day Monday 2026-11-02 (Tue Night washroom), napkins ──
-- 3 first-wash loads on Washer 1; 2 rewash loads on Washer 6 (1.19); 1 rewash load without machine.
insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, machine_id, started_at, load_count, source, entered_by, client_id, is_rewash) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), pg_temp.id('machine'), pg_temp.ny('2026-11-03 01:00'), 3, 'manual', pg_temp.id('lead'), gen_random_uuid(), false),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), '60000000-0000-0000-0000-0000000000a6', pg_temp.ny('2026-11-03 02:00'), 2, 'manual', pg_temp.id('lead'), gen_random_uuid(), true),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), null, pg_temp.ny('2026-11-03 03:00'), 1, 'manual', pg_temp.id('lead'), gen_random_uuid(), true),
-- Tuesday 2026-11-03 (Tue Evening): Towel group with ONLY rewash loads (2).
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gTowel'), pg_temp.id('machine'), pg_temp.ny('2026-11-03 15:00'), 2, 'manual', pg_temp.id('lead'), gen_random_uuid(), true),
-- Plant B rewash (cross-tenant noise).
  (pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), pg_temp.id('groupB'), null, pg_temp.ny('2026-11-03 01:00'), 4, 'manual', pg_temp.id('ownerB'), gen_random_uuid(), true);
-- Finishing: 1000 napkins (500/load) ≈ 2 finished loads on Monday's production day (Tue Day shift).
insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, packs, loose_pieces, occurred_at, entered_by, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('napkin'), 10, 0, pg_temp.ny('2026-11-03 11:00'), pg_temp.id('manager'), gen_random_uuid());

-- ── washroom_by_shift ─────────────────────────────────────────────────────
select is((select array[loads_run::text, rewash_loads::text, standard_loads::text, approximate::text] from public.washroom_by_shift
            where shift_instance_id = pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03') and wash_group_id = pg_temp.id('gNapkin')),
  array['6', '3', '3.00', 'false'],
  'Tue Night napkins: 6 loads run (3 rewash); standard_loads = 3 × 1.00, rewash excluded (its 1.19 factor too, so not approximate)');
select is((select array[loads_run::text, rewash_loads::text, standard_loads::text, approximate::text] from public.washroom_by_shift
            where shift_instance_id = pg_temp.si(pg_temp.id('wash'), 'Evening', '2026-11-03') and wash_group_id = pg_temp.id('gTowel')),
  array['2', '2', '0', 'false'], 'rewash-only shift: loads run and rewash loads 2, standard loads 0');
select is(pg_temp.reads($$select rewash_loads from public.washroom_by_shift where rewash_loads > 0$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'washroom_by_shift: owner-only since 2026-11-05 (no client grant; the owner reads it through the report RPCs)');

-- ── daily_reconciliation ──────────────────────────────────────────────────
select is((select array[loads_run, rewash_loads, standard_loads, pieces_finished, loads_finished_approx, clean_backlog_loads_approx]
             from public.daily_reconciliation where production_date = '2026-11-02' and wash_group_id = pg_temp.id('gNapkin')),
  array[6, 3, 3, 1000, 2, 1]::numeric[],
  'Monday napkins: 6 loads run, 3 rewash; finished ≈ 2 loads compared with 3 standard (first-wash) loads → backlog ≈ 1, not 4.38');
select is((select array[loads_run, rewash_loads, standard_loads, loads_finished_approx, clean_backlog_loads_approx]
             from public.daily_reconciliation where production_date = '2026-11-03' and wash_group_id = pg_temp.id('gTowel')),
  array[2, 2, 0, 0, 0]::numeric[], 'rewash-only day: nothing new washed, so no backlog is created');
select is((select count(*)::int from public.daily_reconciliation where plant_id = pg_temp.id('plantA') and rewash_loads > 0), 3,
  'every reconciliation row with rewash exposes rewash_loads (napkins 11-02, towels 11-03, towels 11-09)');
select is(pg_temp.reads($$select 1 from public.daily_reconciliation where rewash_loads > 0$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'daily_reconciliation: owner-only since 2026-11-05 (no client grant; get_day_report)');

-- Same definition in both views: per production day and group, the shift view sums to the day view.
select is((select array_agg(x order by x) from (
             select (s.loads_run = d.loads_run and s.rewash_loads = d.rewash_loads and s.standard_loads = d.standard_loads) as x
               from (select production_date, wash_group_id, sum(loads_run) loads_run, sum(rewash_loads) rewash_loads, sum(standard_loads) standard_loads
                       from public.washroom_by_shift where plant_id = pg_temp.id('plantA') and wash_group_id is not null group by 1, 2) s
               join public.daily_reconciliation d using (production_date, wash_group_id)) t),
  array[true, true, true], 'washroom_by_shift and daily_reconciliation agree on loads_run, rewash_loads and standard_loads');

-- Column order/types of the replaced views: rewash_loads appended last, nothing else moved.
select is((select attname::text from pg_attribute where attrelid = 'public.washroom_by_shift'::regclass and attnum > 0
            order by attnum desc limit 1), 'rewash_loads', 'washroom_by_shift: rewash_loads is the last column');
select is((select attname::text from pg_attribute where attrelid = 'public.daily_reconciliation'::regclass and attnum > 0
            order by attnum desc limit 1), 'rewash_loads', 'daily_reconciliation: rewash_loads is the last column');

select * from finish();
rollback;
