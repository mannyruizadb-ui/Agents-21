-- M2 launch: report RPCs (G1 shift + day report, G6 pace), in-app setup guards, the revoked direct
-- write paths (ADR 001), wash_groups.ships_next_morning, and the nightly pg_cron shift generation.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(46);

-- ── Data (service role): production day Monday 2026-11-02 ────────────────
insert into public.entry_staff (id, org_id, plant_id, display_name) values
  ('b0000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Ana');
insert into public.machines (id, org_id, plant_id, area_id, name, kind, load_factor) values
  ('60000000-0000-0000-0000-0000000000a6', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 6', 'washer', 1.19),
  ('60000000-0000-0000-0000-0000000000a7', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Spare washer', 'washer', 1.00);
update public.wash_groups set ships_next_morning = true where id = pg_temp.id('gMat');
-- Washroom Tue Night (Monday's production day): napkins 3 loads on Washer 1, 1 rewash on Washer 6, 1 voided.
insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, machine_id, started_at, load_count, source, entered_by, client_id, is_rewash, staff_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), pg_temp.id('machine'), pg_temp.ny('2026-11-03 01:00'), 3, 'manual', pg_temp.id('lead'), gen_random_uuid(), false, null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), '60000000-0000-0000-0000-0000000000a6', pg_temp.ny('2026-11-03 02:00'), 1, 'manual', pg_temp.id('lead'), gen_random_uuid(), true, null),
  -- off-shift (washroom starts 14:00): Monday 12:30 → production day Monday, no instance.
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gMat'), null, pg_temp.ny('2026-11-02 12:30'), 2, 'manual', pg_temp.id('lead'), gen_random_uuid(), false, null);
insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, machine_id, started_at, load_count, source, entered_by, client_id, voided_at, voided_by, void_reason) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), pg_temp.id('machine'), pg_temp.ny('2026-11-03 03:00'), 1, 'manual', pg_temp.id('lead'), gen_random_uuid(), now(), pg_temp.id('lead'), 'undo');
-- Finishing Tue Day: Napkin 7 packs + 34 on Ironer 1 by Ana; Mat 12 without a line.
insert into public.finished_goods_entries (org_id, plant_id, area_id, station_id, item_type_id, packs, loose_pieces, occurred_at, entered_by, staff_id, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('station'), pg_temp.id('napkin'), 7, 34, pg_temp.ny('2026-11-03 11:30'), pg_temp.id('manager'), 'b0000000-0000-0000-0000-0000000000a1', gen_random_uuid()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), null, pg_temp.id('mat'), 0, 12, pg_temp.ny('2026-11-03 11:45'), pg_temp.id('manager'), 'b0000000-0000-0000-0000-0000000000a1', gen_random_uuid());
insert into public.shift_crew_hours (org_id, plant_id, shift_instance_id, area_id, crew_count, labor_hours, entered_by) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03'), pg_temp.id('fin'), 4, 24, pg_temp.id('owner'));
insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, entered_at, client_id, staff_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 5, 'load', pg_temp.id('manager'), pg_temp.ny('2026-11-02 13:00'), gen_random_uuid(), 'b0000000-0000-0000-0000-0000000000a1'),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'),    6, 'load', pg_temp.id('manager'), pg_temp.ny('2026-11-02 13:00'), gen_random_uuid(), null);
-- Washroom queue: 1 done in the Tue Night window, 1 still open.
insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id, created_at) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), 3, 'load', 1, pg_temp.id('owner'), gen_random_uuid(), pg_temp.ny('2026-11-02 20:00')),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gMat'),    2, 'load', 2, pg_temp.id('owner'), gen_random_uuid(), pg_temp.ny('2026-11-02 20:00'));
update public.queue_items set status = 'in_progress', started_at = pg_temp.ny('2026-11-03 00:30') where position = 1 and area_id = pg_temp.id('wash');
update public.queue_items set status = 'done', completed_at = pg_temp.ny('2026-11-03 04:00') where position = 1 and area_id = pg_temp.id('wash');

-- ══ get_shift_report ═════════════════════════════════════════════════════
select is(pg_temp.writes($$select public.get_shift_report(pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03'))$$),
  '{1,1,1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'get_shift_report: owner/manager/lead/viewer; display, other tenant denied; anon no EXECUTE');
select is(array[pg_temp.run_as('ownerB', $$select public.get_shift_report(pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03'))$$),
                pg_temp.run_as('ownerB', $$select public.get_shift_report(gen_random_uuid())$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED}', 'no oracle: another tenant''s shift vs a missing id');
select set_config('test.wr', pg_temp.val_as('viewer', $$select public.get_shift_report(pg_temp.si(pg_temp.id('wash'), 'Night', '2026-11-03'))::text$$), true);
select is((current_setting('test.wr')::jsonb #>> '{shift,name}') || '/' || (current_setting('test.wr')::jsonb #>> '{shift,production_date}') || '/' || (current_setting('test.wr')::jsonb #>> '{shift,area_kind}'),
  'Night/2026-11-02/washroom', 'shift header: Tue Night belongs to Monday''s production day');
select is((current_setting('test.wr')::jsonb -> 'washroom' -> 0) - 'wash_group_name_i18n' - 'wash_group_id',
  '{"wash_group_name":"Napkins","loads_run":4,"standard_loads":3.00,"rewash_loads":1,"approximate":false}'::jsonb,
  'washroom: 4 loads run (1 rewash), 3 standard loads; the voided load is excluded');
select is(current_setting('test.wr')::jsonb -> 'totals', '{"loads_run":4,"standard_loads":3.00,"rewash_loads":1,"pieces":0}'::jsonb, 'washroom totals');
select is(current_setting('test.wr')::jsonb -> 'queue', '{"completed":1,"remaining":1}'::jsonb, 'queue at shift end: 1 completed in the window, 1 remaining');
select is(current_setting('test.wr')::jsonb -> 'finishing', '[]'::jsonb, 'a washroom shift has no finishing rows');
select set_config('test.fr', pg_temp.val_as('lead', $$select public.get_shift_report(pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03'))::text$$), true);
select is((select array_agg(x ->> 'item_name' || ':' || (x ->> 'pieces') || ':' || coalesce(x ->> 'loads_approx', 'null') order by x ->> 'item_name')
             from jsonb_array_elements(current_setting('test.fr')::jsonb -> 'finishing') x),
  array['Mat:12:null', 'Napkin:734:1.4680000000000000'], 'finishing: pieces per item; ≈ loads via pieces_per_load, null without one');
select is((current_setting('test.fr')::jsonb #> '{finishing,1,by_line,0}') - 'station_id',
  '{"station_name":"Ironer 1","packs":7,"loose_pieces":34,"pieces":734}'::jsonb, 'finishing by line');
select ok(not (current_setting('test.fr')::jsonb ? 'crew') and position('labor_hours' in current_setting('test.fr')) = 0,
  'review M1: no crew count / labor hours in the shift report (pending HR/legal review)');
select ok(position('Ana' in current_setting('test.fr')) = 0 and position('b0000000' in current_setting('test.fr')) = 0
          and position('entered_by' in current_setting('test.fr')) = 0, 'no per-person data in the shift report');

-- ══ get_day_report ═══════════════════════════════════════════════════════
select is(pg_temp.writes($$select public.get_day_report(pg_temp.id('plantA'), '2026-11-02')$$),
  '{1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'get_day_report: owner only (owner 2026-11-04)');
select is(array[pg_temp.run_as('ownerB', $$select public.get_day_report(pg_temp.id('plantA'), '2026-11-02')$$),
                pg_temp.run_as('ownerB', $$select public.get_day_report(gen_random_uuid(), '2026-11-02')$$),
                pg_temp.run_as('owner', $$select public.get_day_report(pg_temp.id('plantA'), null)$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,VALIDATION_FAILED}', 'no oracle (foreign vs missing plant); production date required');
select set_config('test.dr', pg_temp.val_as('owner', $$select public.get_day_report(pg_temp.id('plantA'), '2026-11-02')::text$$), true);
select is((select x - 'wash_group_name_i18n' - 'wash_group_id' from jsonb_array_elements(current_setting('test.dr')::jsonb -> 'reconciliation') x
            where x ->> 'wash_group_name' = 'Napkins'),
  '{"wash_group_name":"Napkins","ships_next_morning":false,"est_loads_start":5,"est_loads_end":5,"loads_run":4,"standard_loads":3.00,"rewash_loads":1,
    "pieces_finished":734,"items_finished":1,"pieces_without_conversion":0,"finished_incomplete":false,"loads_finished_approx":1.4680000000000000,
    "loads_finished_partial_approx":1.4680000000000000,"clean_backlog_loads_approx":1.5320000000000000,"approximate":true}'::jsonb,
  'day report: washed vs finished per wash group for the production day');
select is((select x ->> 'finished_incomplete' from jsonb_array_elements(current_setting('test.dr')::jsonb -> 'reconciliation') x
            where x ->> 'wash_group_name' = 'Mats'), 'true', 'mats without pieces_per_load: no guessed conversion');
select is(current_setting('test.dr')::jsonb -> 'off_shift', '{"loads_run":2,"standard_loads":2,"pieces":0}'::jsonb,
  'off-shift loads count in the day, shown separately');
select is(current_setting('test.dr')::jsonb -> 'totals', '{"loads_run":6,"standard_loads":5.00,"rewash_loads":1,"pieces_finished":746}'::jsonb, 'day totals');
select is(jsonb_array_length(current_setting('test.dr')::jsonb -> 'shifts'), 5, 'the day''s shifts (washroom Evening + Night, finishing Evening + Night + Day)');
select is((select array_agg(x ->> 'wash_group_name' order by x ->> 'wash_group_name') from jsonb_array_elements(current_setting('test.dr')::jsonb -> 'soil') x),
  array['Mats', 'Napkins'], 'soil start/end for every group with an estimate');
select ok(position('Ana' in current_setting('test.dr')) = 0 and position('b0000000' in current_setting('test.dr')) = 0, 'no per-person data in the day report');

-- ══ get_wash_group_pace ══════════════════════════════════════════════════
select is(pg_temp.writes($$select * from public.get_wash_group_pace(pg_temp.id('plantA'), '2026-11-02')$$),
  '{3,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'get_wash_group_pace: one row per active group; owner only (owner 2026-11-04)');
select is(pg_temp.val_as('owner', $$select array_agg(wash_group_name || ':' || ships_next_morning || ':' || loads_run || ':' || standard_loads || ':' || coalesce(estimate_loads::text, 'null') order by 1)::text
                                     from (select * from public.get_wash_group_pace(pg_temp.id('plantA'), '2026-11-02')) p$$),
  '{Mats:true:2:2.00:6.00,Napkins:false:4:3.00:5.00,Towels:false:0:0:null}', 'pace: loads today per group, next-morning flag, latest estimate in loads');
select is(pg_temp.val_as('owner', $$select wash_group_name from public.get_wash_group_pace(pg_temp.id('plantA'), '2026-11-02') limit 1$$),
  'Mats', 'next-morning groups come first');
select is(pg_temp.val_as('owner', $$select row(standard_loads_since_estimate, backlog_loads_approx)::text from public.get_wash_group_pace(pg_temp.id('plantA'), '2026-11-02') where wash_group_name = 'Napkins'$$),
  '(3.00,2.00)', 'backlog ≈ estimate − first-wash standard loads since it (rewash and voided loads excluded)');
select ok(pg_temp.val_as('owner', $$select count(*) from public.get_wash_group_pace(pg_temp.id('plantA'))$$)::int = 3, 'default: the current production day');

-- ══ Revoked direct writes (ADR 001) ══════════════════════════════════════
select is((select array_agg(t || ':' || p order by t, p) from unnest(array['queue_items', 'soil_estimates', 'washer_cycles', 'finished_goods_entries']) t
             cross join unnest(array['INSERT', 'UPDATE', 'DELETE']) p
            where has_table_privilege('authenticated', 'public.' || t, p) or has_table_privilege('anon', 'public.' || t, p)),
  null, 'no client INSERT/UPDATE/DELETE privilege on the operational tables');
select is((select array_agg(tablename || ':' || cmd order by tablename) from pg_policies
            where schemaname = 'public' and tablename in ('queue_items', 'soil_estimates', 'washer_cycles', 'finished_goods_entries')),
  array['finished_goods_entries:SELECT', 'queue_items:SELECT', 'soil_estimates:SELECT', 'washer_cycles:SELECT'], 'only SELECT policies remain');
select ok(has_any_column_privilege('authenticated', 'public.washer_cycles', 'SELECT')
          and not has_column_privilege('authenticated', 'public.washer_cycles', 'entered_by', 'SELECT'),
  'reads stay (column-level since 2026-11-04: who-entered columns hidden)');

-- ══ Setup edits (owner 2026-11-03): direct writes, column-limited, with history guards ══
select is(array[pg_temp.run_as('owner', $$update public.machines set plant_id = pg_temp.id('plantA2') where id = pg_temp.id('machine')$$),
                pg_temp.run_as('owner', $$update public.item_types set org_id = pg_temp.id('orgB') where id = pg_temp.id('mat')$$),
                pg_temp.run_as('owner', $$update public.shifts set area_id = pg_temp.id('spare') where id = pg_temp.id('washNight')$$),
                pg_temp.run_as('owner', $$update public.wash_groups set id = gen_random_uuid() where id = pg_temp.id('gMat')$$)],
  '{42501,42501,42501,42501}', 'tenant, id and shift-area columns are not updatable by clients');
select is(pg_temp.writes($$update public.wash_groups set ships_next_morning = true, loads_per_basket = 3, allow_basket_estimates = true, loads_per_bin = 2, allow_bin_estimates = true where id = pg_temp.id('gNapkin')$$),
  '{1,1,0,0,0,0,0,0}', 'wash group settings (next-morning, loads per basket / bin): owner/manager');
select is(pg_temp.writes($$update public.machines set load_factor = 1.10, name = name where id = '60000000-0000-0000-0000-0000000000a7'$$),
  '{1,1,0,0,0,0,0,0}', 'machine edits: owner/manager');
select is(array[pg_temp.run_as('manager', $$update public.machines set kind = 'dryer' where id = pg_temp.id('machine')$$),
                pg_temp.run_as('manager', $$update public.machines set area_id = pg_temp.id('spare') where id = '60000000-0000-0000-0000-0000000000a6'$$),
                pg_temp.run_as('manager', $$update public.machines set kind = 'dryer' where id = '60000000-0000-0000-0000-0000000000a7'$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,1}', 'a machine with washer loads keeps its kind and area; an unused one can change');
select is(array[pg_temp.run_as('owner', $$update public.areas set kind = 'finishing' where id = pg_temp.id('wash')$$),
                pg_temp.run_as('owner', $$update public.areas set kind = 'packing' where id = pg_temp.id('spare')$$)],
  '{VALIDATION_FAILED,1}', 'an area in use keeps its kind; an unused one can change');
select is(array[pg_temp.run_as('owner', $$update public.item_types set count_mode = 'pack', pack_size = 25 where id = pg_temp.id('mat')$$),
                pg_temp.run_as('owner', $$update public.item_types set count_mode = 'pack', pack_size = 25 where id = pg_temp.id('towel')$$)],
  '{VALIDATION_FAILED,1}', 'count mode is fixed once finished goods exist; free before');
select is(pg_temp.run_as('ownerB', $$update public.machines set kind = 'dryer' where id = pg_temp.id('machine')$$), '0',
  'the guard never runs for another tenant''s row (RLS first, no oracle)');
select ok((select count(*) >= 1 from public.audit_log where entity = 'wash_groups' and after ->> 'ships_next_morning' = 'true'), 'setup edits are audited');

-- Shift edits regenerate future instances at once (client edits only).
select is(pg_temp.run_as('owner', $$update public.shifts set start_local = '14:30' where id = pg_temp.id('washEvening')$$), '1', 'owner moves washroom Evening to 14:30');
select ok((select bool_and((si.starts_at at time zone 'America/New_York')::time = '14:30') and count(*) > 0
             from public.shift_instances si where si.shift_id = pg_temp.id('washEvening') and si.starts_at > now() and si.skipped_at is null),
  'every future Evening instance starts at 14:30');
select is((select (starts_at at time zone 'America/New_York')::time from public.shift_instances where id = pg_temp.si(pg_temp.id('wash'), 'Evening', '2026-11-02')),
  '14:00'::time, 'a past instance keeps its time');
select ok((select count(*) > 0 from public.shift_instances si where si.shift_id = pg_temp.id('washEvening') and si.business_date > current_date + 7),
  'instances exist for the next 14 days');
select is(pg_temp.run_as('manager', $$insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week)
  values ('90000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Pack', '08:00', '12:00', '{0,1,2,3,4,5,6}')$$), '1',
  'a manager adds a shift');
select ok((select count(*) >= 13 from public.shift_instances where shift_id = '90000000-0000-0000-0000-0000000000d1'), 'its instances exist immediately');
update public.shifts set start_local = '07:00' where id = '90000000-0000-0000-0000-0000000000d1';
select ok((select bool_and((starts_at at time zone 'America/New_York')::time = '08:00') from public.shift_instances where shift_id = '90000000-0000-0000-0000-0000000000d1'),
  'service-role edits wait for the nightly run (no regeneration in the trigger)');

-- ══ ships_next_morning seed + pg_cron ════════════════════════════════════
select col_default_is('public', 'wash_groups', 'ships_next_morning', 'false', 'ships_next_morning defaults to false');
select is((select array_agg(g.name order by g.sort_order) from public.wash_groups g join public.plants p on p.id = g.plant_id
            where p.name = 'Miami' and g.ships_next_morning),
  array['Black mats', 'Colored mats', 'Charcoal mats', 'Scraper mats', 'City & Brito mats', 'Presidente logo mats', 'Logo mats',
        'Coats (white)', 'Old sheets', 'Regular sheets', 'New sheets'], 'seed: mats, sheets and white coats ship next morning');
select is((select schedule || ' | ' || command from cron.job where jobname = 'generate-shift-instances'),
  '15 3 * * * | select app.generate_all_shift_instances(14)', 'pg_cron: nightly 03:15 UTC, next 14 days, all plants');

select * from finish();
rollback;
