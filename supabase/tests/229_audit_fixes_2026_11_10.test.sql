-- Audit fixes 2026-11-10 + owner decisions of the same day:
--   1. a late offline estimate no longer double-counts loads (app.sync_estimate_queue_item, 20261110104601)
--   2. whole loads = ceil(round(loads, 2)), as the app (app.queue_loads_needed, 20261110104559)
--   3. managers enter / void finished goods only in the current or next shift (20261110104603)
--   4. the entry-PIN RPCs are service_role only (20261110104605)
--   5. load-out comments say pieces (20261110104608)
--   7. one "loads left" rule: current_soil_estimates.loads_left; get_wash_group_pace counts starts (20261110105124)
-- (6, production day 10:00, is in 032_production_day.)
begin;
\ir _fixtures.psql
select plan(49);

-- Own wash groups for each scenario (loads unless noted); gRound: 0.667 loads per basket; gNoF: no factor.
insert into public.wash_groups (id, org_id, plant_id, name, allow_basket_estimates, loads_per_basket) values
  ('71000000-0000-0000-0000-0000000f0001', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Late', false, null),
  ('71000000-0000-0000-0000-0000000f0002', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Done', false, null),
  ('71000000-0000-0000-0000-0000000f0003', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Zero', false, null),
  ('71000000-0000-0000-0000-0000000f0004', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Round', true, 0.667),
  ('71000000-0000-0000-0000-0000000f0005', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Left', false, null),
  ('71000000-0000-0000-0000-0000000f0006', pg_temp.id('orgA'), pg_temp.id('plantA'), 'NoF', true, 1);
create function pg_temp.g(p text) returns uuid language sql immutable as $$
  select (case p when 'late' then '71000000-0000-0000-0000-0000000f0001' when 'done' then '71000000-0000-0000-0000-0000000f0002'
                 when 'zero' then '71000000-0000-0000-0000-0000000f0003' when 'round' then '71000000-0000-0000-0000-0000000f0004'
                 when 'left' then '71000000-0000-0000-0000-0000000f0005' when 'nof' then '71000000-0000-0000-0000-0000000f0006' end)::uuid;
$$;
grant execute on function pg_temp.g(text) to authenticated, anon;
-- A manager's estimate entered p_ago before the transaction's now() (an offline entry arriving now).
create function pg_temp.est(p_group text, p_qty numeric, p_unit text, p_ago interval) returns text language sql as $$
  select pg_temp.run_as('manager', format($q$select public.record_soil_estimate(pg_temp.g(%L), %s, %L, gen_random_uuid(), p_entered_at => now() - %L::interval)$q$,
                                          p_group, p_qty, p_unit, p_ago));
$$;
-- A lead's washer start (Washer 1) tapped p_ago before now(), on p_item, else off-queue for p_group.
create function pg_temp.tap(p_client text, p_ago interval, p_item uuid default null, p_group text default null) returns text language sql as $$
  select pg_temp.run_as('lead', format($q$select public.start_washer_load(pg_temp.id('machine'), %L::uuid, %L::uuid, pg_temp.g(%L), now() - %L::interval,
                                                                          p_confirm_running => true, p_off_queue_reason => 'other')$q$,
                                       p_client, p_item, p_group, p_ago));
$$;
-- The open from_estimate item of a group, and its get_queue row as the manager.
create function pg_temp.ei(p_group text) returns uuid language sql stable as $$
  select q.id from public.queue_items q
   where q.area_id = '30000000-0000-0000-0000-0000000000a1' and q.wash_group_id = pg_temp.g(p_group) and q.from_estimate and q.status in ('queued', 'in_progress');
$$;
create function pg_temp.gq(p_item uuid) returns text language sql as $$
  select pg_temp.val_as('manager', format($q$select row(b.qty, b.unit, b.status, b.loads_started, b.loads_needed, b.loads_remaining)::text
                                              from public.get_queue(pg_temp.id('wash')) b where b.id = %L$q$, p_item));
$$;
create function pg_temp.left_(p_group text, p_user text default 'manager') returns text language sql as $$
  select pg_temp.val_as(p_user, format($q$select coalesce(c.loads_left::text, 'null') from public.current_soil_estimates c where c.wash_group_id = pg_temp.g(%L)$q$, p_group));
$$;

-- ══ 1. Late offline estimate, in-progress item (the audit scenario) ══════
select is(pg_temp.est('late', 5, 'load', '20 minutes'), '1', 'Late: 5 loads estimated at T−5 → an estimate item');
select set_config('test.late', pg_temp.ei('late')::text, true);
select is(array[pg_temp.tap('fa000000-0000-0000-0000-000000000001', '10 minutes', current_setting('test.late')::uuid),
                pg_temp.tap('fa000000-0000-0000-0000-000000000002', '5 minutes', current_setting('test.late')::uuid)],
  '{1,1}', 'two starts on the item at T+5 and T+10');
select is(pg_temp.est('late', 3, 'load', '15 minutes'), '1', 'the manager''s offline estimate of 3 loads, entered at T, arrives at T+15');
select is(pg_temp.gq(current_setting('test.late')::uuid), '(3.00,load,in_progress,2,3,1)',
  'qty = 2 started + (3 − 2 starts since T) = 3: 1 load left, not 3 (the starts after T washed part of the estimate)');
select is(pg_temp.left_('late'), '1', 'current_soil_estimates.loads_left agrees: 1');

-- ══ 1b. Late estimate after the item finished ════════════════════════════
select is(pg_temp.est('done', 2, 'load', '20 minutes'), '1', 'Done: 2 loads estimated at T−5');
select set_config('test.done', pg_temp.ei('done')::text, true);
select is(array[pg_temp.tap('fa000000-0000-0000-0000-000000000011', '10 minutes', current_setting('test.done')::uuid),
                pg_temp.tap('fa000000-0000-0000-0000-000000000012', '5 minutes', current_setting('test.done')::uuid)],
  '{1,1}', 'two starts at T+5 / T+10 …');
select is((select status::text from public.queue_items where id = current_setting('test.done')::uuid), 'done', '… finish that item');
select is(pg_temp.est('done', 3, 'load', '15 minutes'), '1', 'a late estimate of 3 loads entered at T');
select set_config('test.done2', pg_temp.ei('done')::text, true);
select is(array[(current_setting('test.done2') <> current_setting('test.done'))::text, pg_temp.gq(current_setting('test.done2')::uuid), pg_temp.left_('done')],
  array['true', '(1.00,load,queued,0,1,1)', '1'],
  'no open item: a new one with 3 − 2 starts since T = 1 load (not 3); loads_left agrees');
select is(pg_temp.est('done', 2, 'load', '12 minutes'), '1', 'a later offline estimate (T+3) of 2 loads: both starts came after it');
select is(array[(select status::text from public.queue_items where id = current_setting('test.done2')::uuid), coalesce(pg_temp.ei('done')::text, 'none'), pg_temp.left_('done')],
  array['cancelled', 'none', '0'], 'nothing left (2 − 2): the not-started item is cancelled; loads_left 0');
select is(pg_temp.est('zero', 1, 'load', '20 minutes'), '1', 'Zero: 1 load at T−5');
select is(pg_temp.tap('fa000000-0000-0000-0000-000000000021', '10 minutes', pg_temp.ei('zero')), '1', 'a start at T+5 finishes it');
select is(pg_temp.est('zero', 1, 'load', '15 minutes'), '1', 'a late 1-load estimate entered at T');
select is(array[coalesce(pg_temp.ei('zero')::text, 'none'), (select count(*)::text from public.queue_items where wash_group_id = pg_temp.g('zero'))],
  array['none', '1'], 'the start since T covers it: no new item is opened');

-- ══ 2. Whole loads: ceil(round(x, 2)), as the app ═══════════════════════
select is(array[app.to_loads(pg_temp.g('round'), null, 3, 'basket')::text, app.queue_loads_needed(pg_temp.g('round'), null, 3, 'basket')::text,
                app.queue_loads_needed(pg_temp.g('round'), null, 2.006, 'load')::text, app.queue_loads_needed(pg_temp.g('round'), null, 2.01, 'load')::text],
  array['2.001', '2', '3', '3'], 'app.queue_loads_needed: 3 × 0.667 = 2.001 → 2 (app wholeLoads); 2.006 → round 2.01 → 3; 2.01 → 3');
select is(pg_temp.est('round', 3, 'basket', '30 minutes'), '1', 'Round: 3 baskets (0.667 loads each)');
select set_config('test.round', pg_temp.ei('round')::text, true);
select is(array[pg_temp.gq(current_setting('test.round')::uuid), pg_temp.left_('round')],
  array['(3.00,basket,queued,0,2,2)', '2'], 'queue loads_needed 2 and loads_left 2 (not 3)');
select is(pg_temp.tap('fa000000-0000-0000-0000-000000000031', '28 minutes', current_setting('test.round')::uuid), '1', 'one start');
select is(pg_temp.est('round', 3, 'basket', '25 minutes'), '1', 'still 3 baskets dirty after it');
select is(array[pg_temp.gq(current_setting('test.round')::uuid), pg_temp.left_('round')],
  array['(3.00,load,in_progress,1,3,2)', '2'],
  'in progress: qty = 1 + round(2.001, 2) = 3.00 (was rounded UP to 3.01 → 4 loads needed); 2 left on both');

-- ══ 7. loads_left: one rule, each start = 1 load ═════════════════════════
select is(pg_temp.tap('fa000000-0000-0000-0000-000000000041', '26 minutes', null, 'left'), '1', 'Left: an off-queue start BEFORE the estimate');
select is(pg_temp.est('left', 6, 'load', '20 minutes'), '1', 'Left: 6 loads estimated');
select set_config('test.left', pg_temp.ei('left')::text, true);
select is(array[pg_temp.tap('fa000000-0000-0000-0000-000000000042', '15 minutes', current_setting('test.left')::uuid),
                pg_temp.tap('fa000000-0000-0000-0000-000000000043', '12 minutes', current_setting('test.left')::uuid),
                pg_temp.tap('fa000000-0000-0000-0000-000000000044', '9 minutes', current_setting('test.left')::uuid),
                pg_temp.tap('fa000000-0000-0000-0000-000000000045', '6 minutes', current_setting('test.left')::uuid),
                pg_temp.tap('fa000000-0000-0000-0000-000000000046', '3 minutes', current_setting('test.left')::uuid)],
  '{1,1,1,1,1}', 'five starts after it');
select set_config('test.cyc', (select id::text from public.washer_cycles where client_id = 'fa000000-0000-0000-0000-000000000046'), true);
select is(pg_temp.run_as('lead', $$select public.undo_washer_load(current_setting('test.cyc')::uuid)$$),
  '1', 'the fifth is undone (voided)');
select is(array[pg_temp.left_('left'), pg_temp.gq(current_setting('test.left')::uuid)],
  array['2', '(6.00,load,in_progress,4,6,2)'],
  '6 − 4 live starts since the estimate = 2 (the earlier start and the voided one do not count); the estimate item''s loads_remaining agrees');
select is(array[pg_temp.left_('left', 'owner'), pg_temp.left_('left', 'lead'), pg_temp.left_('left', 'viewer'), pg_temp.left_('left', 'display')],
  '{2,2,2,2}', 'same number for every reader (the starts are outside any running shift, which washer_cycles RLS hides from managers)');
select is(pg_temp.reads($$select loads_left from public.current_soil_estimates where wash_group_id = pg_temp.g('left')$$),
  '{1,1,1,1,1,0,0,42501}', 'current_soil_estimates readers unchanged (no device display, other tenant: no row; anon: no grant)');
select is(array[pg_temp.val_as('ownerB', $$select coalesce(app.estimate_starts_since(pg_temp.id('plantA'), pg_temp.g('left'), now() - interval '1 day')::text, 'null')$$),
                pg_temp.val_as('manager', $$select app.estimate_starts_since(pg_temp.id('plantA'), pg_temp.g('left'), now() - interval '1 day')::text$$)],
  array['null', '5'], 'the definer counter answers only readers of the plant (another tenant gets null)');
select is((select attname::text from pg_attribute where attrelid = 'public.current_soil_estimates'::regclass and attnum > 0 and not attisdropped order by attnum desc limit 1),
  'loads_left', 'loads_left is the last column');
select is((select reloptions::text from pg_class where oid = 'public.current_soil_estimates'::regclass), '{security_invoker=true}', 'still security_invoker');
select pg_temp.as_service($$insert into public.soil_estimates (org_id, plant_id, wash_group_id, qty, unit, entered_by, client_id, entered_at)
                           values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.g('nof'), 2, 'basket', pg_temp.id('manager'), gen_random_uuid(), now())$$);
select pg_temp.as_service($$update public.wash_groups set allow_basket_estimates = false, loads_per_basket = null where id = pg_temp.g('nof')$$);
select is((select row(c.has_conversion, coalesce(c.loads_left::text, 'null'))::text from public.current_soil_estimates c where c.wash_group_id = pg_temp.g('nof')),
  '(f,null)', 'no factor: loads_left null (never a guess)');
select is(pg_temp.val_as('owner', $$select row(p.standard_loads_since_estimate, p.backlog_loads_approx)::text from public.get_wash_group_pace(pg_temp.id('plantA')) p where p.wash_group_id = pg_temp.g('left')$$),
  '(4,2.00)', 'get_wash_group_pace counts starts since the estimate (each = 1 load): 4, backlog 6 − 4');

-- ══ 3. Finished goods: managers in the current or next shift only ═══════
-- Finishing 2: a past, the current and the next instance around now(). Finishing 3: off-shift now, its
-- last instance ended 3 h ago.
insert into public.areas (id, org_id, plant_id, name, kind) values
  ('30000000-0000-0000-0000-0000000000f2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Finishing 2', 'finishing'),
  ('30000000-0000-0000-0000-0000000000f3', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Finishing 3', 'finishing');
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week) values
  ('90000000-0000-0000-0000-0000000f0001', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f2', 'Past', '00:00', '01:00', '{0}'),
  ('90000000-0000-0000-0000-0000000f0002', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f2', 'Now',  '02:00', '03:00', '{0}'),
  ('90000000-0000-0000-0000-0000000f0003', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f2', 'Next', '04:00', '05:00', '{0}'),
  ('90000000-0000-0000-0000-0000000f0004', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f3', 'Past', '00:00', '01:00', '{0}');
-- Drop what the shift insert trigger generated from the wall clock; the test places its own instances.
delete from public.shift_instances where area_id in ('30000000-0000-0000-0000-0000000000f2', '30000000-0000-0000-0000-0000000000f3');
insert into public.shift_instances (id, org_id, plant_id, area_id, shift_id, business_date, starts_at, ends_at) values
  ('91000000-0000-0000-0000-0000000f0001', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f2', '90000000-0000-0000-0000-0000000f0001', '2026-01-01', now() - interval '20 hours', now() - interval '12 hours'),
  ('91000000-0000-0000-0000-0000000f0002', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f2', '90000000-0000-0000-0000-0000000f0002', '2026-01-01', now() - interval '2 hours', now() + interval '6 hours'),
  ('91000000-0000-0000-0000-0000000f0003', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f2', '90000000-0000-0000-0000-0000000f0003', '2026-01-01', now() + interval '6 hours', now() + interval '14 hours'),
  ('91000000-0000-0000-0000-0000000f0004', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f3', '90000000-0000-0000-0000-0000000f0004', '2026-01-01', now() - interval '11 hours', now() - interval '3 hours');
-- record_finished_goods (1 mat) in area p_area at now() − p_ago with p_choice; returns shift instance id or the error.
create function pg_temp.fg(p_user text, p_area text, p_ago interval, p_choice text default 'own', p_client uuid default gen_random_uuid()) returns text language sql as $$
  select pg_temp.val_as(p_user, format($q$select coalesce((public.record_finished_goods(pg_temp.id('mat'), 0, 1, %L::uuid, null, p_shift_choice => %L,
                                                            p_area_id => %L::uuid, p_occurred_at => now() - %L::interval)).shift_instance_id::text, 'off-shift')$q$,
                                       p_client, p_choice, p_area, p_ago));
$$;
select is(array[pg_temp.fg('manager', '30000000-0000-0000-0000-0000000000f2', '1 hour'),
                pg_temp.fg('manager', '30000000-0000-0000-0000-0000000000f2', '0', 'next')],
  array['91000000-0000-0000-0000-0000000f0002', '91000000-0000-0000-0000-0000000f0003'],
  'manager: the current shift and the next one are allowed');
select is(pg_temp.fg('manager', '30000000-0000-0000-0000-0000000000f2', '15 hours', 'next'), '91000000-0000-0000-0000-0000000f0002',
  'manager: a late entry from the previous shift booked as "next" lands in the current shift (allowed)');
select is(array[pg_temp.fg('manager', '30000000-0000-0000-0000-0000000000f2', '15 hours'),
                pg_temp.fg('manager', '30000000-0000-0000-0000-0000000000f2', '5 hours'),
                pg_temp.fg('manager', '30000000-0000-0000-0000-0000000000f2', '7 days')],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}',
  'manager: back-dated into a past shift, into the off-shift gap before the current shift, or a week back → NOT_AUTHORIZED');
select is(array[pg_temp.fg('owner', '30000000-0000-0000-0000-0000000000f2', '15 hours', 'own', 'fb000000-0000-0000-0000-000000000001'),
                pg_temp.fg('owner', '30000000-0000-0000-0000-0000000000f2', '5 hours')],
  array['91000000-0000-0000-0000-0000000f0001', 'off-shift'], 'the owner still back-dates (past shift, off-shift)');
select is(array[pg_temp.fg('manager', '30000000-0000-0000-0000-0000000000f3', '1 hour'),
                pg_temp.fg('manager', '30000000-0000-0000-0000-0000000000f3', '5 hours'),
                pg_temp.fg('manager', '30000000-0000-0000-0000-0000000000f3', '12 hours')],
  array['off-shift', 'NOT_AUTHORIZED', 'NOT_AUTHORIZED'],
  'area off-shift now: a manager enters in the current off-shift gap; not in the last shift, nor before it');
select is(pg_temp.val_as('manager', $$select (public.record_finished_goods(pg_temp.id('mat'), 0, 1, 'fb000000-0000-0000-0000-000000000001', null)).duplicate::text$$),
  'true', 'an idempotent retry still returns the saved entry');
-- void_finished_goods
select set_config('test.cur', (select id::text from public.finished_goods_entries where entered_by = pg_temp.id('manager') and shift_instance_id = '91000000-0000-0000-0000-0000000f0002' limit 1), true);
select set_config('test.nxt', (select id::text from public.finished_goods_entries where shift_instance_id = '91000000-0000-0000-0000-0000000f0003' limit 1), true);
select set_config('test.gap', (select id::text from public.finished_goods_entries where area_id = '30000000-0000-0000-0000-0000000000f3' limit 1), true);
select set_config('test.old', (select id::text from public.finished_goods_entries where client_id = 'fb000000-0000-0000-0000-000000000001'), true);
select is(array[pg_temp.run_as('manager', $$select public.void_finished_goods(current_setting('test.cur')::uuid, 'typo')$$),
                pg_temp.run_as('manager', $$select public.void_finished_goods(current_setting('test.nxt')::uuid, 'typo')$$),
                pg_temp.run_as('manager', $$select public.void_finished_goods(current_setting('test.gap')::uuid, 'typo')$$)],
  '{1,1,1}', 'manager voids entries of the current shift, the next shift and the current off-shift gap');
select is(pg_temp.run_as('manager', $$select public.void_finished_goods(current_setting('test.old')::uuid, 'typo')$$),
  'NOT_AUTHORIZED', 'manager cannot void an entry of a past shift');
select is(array[pg_temp.run_as('owner', $$select public.void_finished_goods(current_setting('test.old')::uuid, 'typo')$$),
                pg_temp.run_as('manager', $$select public.void_finished_goods(current_setting('test.old')::uuid, 'typo')$$)],
  '{1,NOT_AUTHORIZED}', 'the owner voids it; the manager still gets NOT_AUTHORIZED (not "already voided": no oracle)');
select ok(not has_function_privilege('authenticated', 'app.fg_manager_window_ok(uuid, uuid, timestamptz)', 'execute')
          and not has_function_privilege('anon', 'app.fg_manager_window_ok(uuid, uuid, timestamptz)', 'execute'),
  'the window helper is internal');

-- ══ 4. Entry-PIN RPCs: service_role only ═════════════════════════════════
select is(array[has_function_privilege('authenticated', 'public.start_staff_session(uuid, text)', 'execute'),
                has_function_privilege('anon', 'public.start_staff_session(uuid, text)', 'execute'),
                has_function_privilege('authenticated', 'public.set_staff_pin(uuid, text)', 'execute'),
                has_function_privilege('anon', 'public.set_staff_pin(uuid, text)', 'execute'),
                has_function_privilege('service_role', 'public.start_staff_session(uuid, text)', 'execute'),
                has_function_privilege('service_role', 'public.set_staff_pin(uuid, text)', 'execute')],
  array[false, false, false, false, true, true], 'start_staff_session / set_staff_pin: no client grant; service_role keeps them');
select is(array[pg_temp.run_as('manager', $$select public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '2580')$$),
                pg_temp.run_as('owner', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a1', '2580')$$),
                pg_temp.run_as('anon', $$select public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '2580')$$)],
  '{42501,42501,42501}', 'signed-in and anonymous callers get permission denied');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname ~ '(staff|pin)'
              and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))),
  0, 'no public staff / PIN function is client-executable');

-- ══ 5. Load-out comments: pieces ═════════════════════════════════════════
select ok(obj_description('public.load_out_lines'::regclass, 'pg_class') ~ 'PIECES'
          and obj_description('public.load_out_lines'::regclass, 'pg_class') !~ 'packs for pack items'
          and obj_description('public.set_load_out_line(uuid, date, uuid, int, uuid, text)'::regprocedure, 'pg_proc') ~ 'PIECES'
          and obj_description('public.set_load_out_line(uuid, date, uuid, int, uuid, text)'::regprocedure, 'pg_proc') !~ 'packs for pack items',
  'load_out_lines and set_load_out_line say pieces for every item');

-- ══ Other comments: no stale 12:00 production day ════════════════════════
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('public', 'app') and obj_description(p.oid, 'pg_proc') ~ '12:00 ?(→|->) ?12:00'), 0,
  'no function comment still says the production day is 12:00 → 12:00');

select * from finish();
rollback;
