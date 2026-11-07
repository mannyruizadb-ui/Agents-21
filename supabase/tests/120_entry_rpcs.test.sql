-- M2 entry RPCs (PRD B1, E1, E4): record_soil_estimate, record_finished_goods, void_finished_goods.
-- Role matrix, validation, shift attribution, idempotency, no-oracle checks. Since 2026-11-07 (owner: one
-- sign-in method) entries need NO name + PIN: p_staff_session_id is optional and ignored, staff_id is null,
-- entered_by = the account, and the finished-goods shift is the area's clock shift (app.clock_entry_shift).
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(42);

-- Entry staff: Ana (home shift finishing Evening), Ben (no home shift), Cy (inactive later), Zed (plant B).
insert into public.entry_staff (id, org_id, plant_id, display_name, home_shift_id, pin_hash) values
  ('b0000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Ana', pg_temp.id('finEvening'), extensions.crypt('2580', extensions.gen_salt('bf'))),
  ('b0000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Ben', null, extensions.crypt('1470', extensions.gen_salt('bf'))),
  ('b0000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Cy', null, extensions.crypt('3690', extensions.gen_salt('bf'))),
  ('b0000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), 'Zed', null, extensions.crypt('2580', extensions.gen_salt('bf')));

-- A confirmed staff session for p_user (name + PIN), as text.
create function pg_temp.sess(p_user text, p_staff text, p_pin text) returns uuid language sql as $$
  select pg_temp.val_as(p_user, format('select (public.start_staff_session(%L, %L)).staff_session_id', p_staff, p_pin))::uuid;
$$;
create function pg_temp.cid(n int) returns uuid language sql immutable as $$
  select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;
$$;
grant execute on function pg_temp.cid(int) to authenticated, anon;
-- Session SQL fragment usable inside run_as / writes (the caller confirms Ana's PIN itself).
create function pg_temp.ana() returns uuid language sql as $$
  select (public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '2580')).staff_session_id;
$$;
grant execute on function pg_temp.ana() to authenticated, anon;

-- ══ record_soil_estimate (B1) ═════════════════════════════════════════════
select is(pg_temp.writes($$select public.record_soil_estimate(pg_temp.id('gNapkin'), 4, 'load', gen_random_uuid(), pg_temp.ana())$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'record_soil_estimate: owner/manager with a staff session (lead, viewer, display, other tenant: NOT_AUTHORIZED; anon: no EXECUTE)');
select is((select array[count(*)::text, bool_and(staff_id is null)::text,
                        string_agg(entered_by::text, ',' order by entered_by)]
             from public.soil_estimates where wash_group_id = pg_temp.id('gNapkin')),
  array['2', 'true', pg_temp.id('owner')::text || ',' || pg_temp.id('manager')::text], 'no PIN: staff_id is null even when a session id is sent; entered_by = the account');

select set_config('test.s1', pg_temp.sess('manager', 'b0000000-0000-0000-0000-0000000000a2', '1470')::text, true);
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gTowel'), 6, 'basket', pg_temp.cid(1), current_setting('test.s1')::uuid, ' recount ')$$),
  '1', 'basket estimate for a group that allows baskets');
select is((select array[qty::text, unit::text, note] from public.soil_estimates where client_id = pg_temp.cid(1)),
  array['6.00', 'basket', 'recount'], 'stored as entered (note trimmed)');
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gTowel'), 7, 'basket', gen_random_uuid(), current_setting('test.s1')::uuid)$$),
  '1', 'a spent session id is ignored (no PIN since 2026-11-07)');
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gTowel'), 6, 'basket', pg_temp.cid(1), current_setting('test.s1')::uuid)$$),
  '1', 'an offline retry of a saved entry succeeds although its session is spent');
select is((select count(*)::int from public.soil_estimates where client_id = pg_temp.cid(1)), 1, 'idempotent: one row');

-- Session rules: the caller's own, unexpired, active person.
select set_config('test.s2', pg_temp.sess('lead', 'b0000000-0000-0000-0000-0000000000a2', '1470')::text, true);
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gMat'), 1, 'load', gen_random_uuid(), current_setting('test.s2')::uuid)$$),
  '1', 'another account''s session id is ignored too (never used for attribution)');
select set_config('test.s3', pg_temp.sess('manager', 'b0000000-0000-0000-0000-0000000000a2', '1470')::text, true);
update public.staff_sessions set confirmed_at = now() - interval '10 minutes', expires_at = now() - interval '1 minute' where id = current_setting('test.s3')::uuid;
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gMat'), 1, 'load', gen_random_uuid(), current_setting('test.s3')::uuid)$$),
  '1', 'an expired session id is ignored');
select set_config('test.s4', pg_temp.sess('manager', 'b0000000-0000-0000-0000-0000000000a3', '3690')::text, true);
update public.entry_staff set active = false where id = 'b0000000-0000-0000-0000-0000000000a3';
select is(array[pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gMat'), 1, 'load', gen_random_uuid(), current_setting('test.s4')::uuid)$$),
                pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gMat'), 1, 'load', gen_random_uuid(), null)$$),
                pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gMat'), 1, 'load', gen_random_uuid(), gen_random_uuid())$$)],
  '{1,1,1}', 'a deactivated person''s session, no session, an unknown session: all accepted (the account is the attribution)');
-- PIN reuse window: the session stays valid for several entries.
update public.plants set staff_pin_reuse_minutes = 10 where id = pg_temp.id('plantA');
select set_config('test.s5', pg_temp.sess('manager', 'b0000000-0000-0000-0000-0000000000a2', '1470')::text, true);
select is(array[pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gMat'), 1, 'load', gen_random_uuid(), current_setting('test.s5')::uuid)$$),
                pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gMat'), 0, 'load', gen_random_uuid(), current_setting('test.s5')::uuid)$$)],
  '{1,1}', 'with staff_pin_reuse_minutes = 10 one confirmation covers several entries (0 = cleared)');
update public.plants set staff_pin_reuse_minutes = 0 where id = pg_temp.id('plantA');

-- Validation.
select is(array[
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 3, 'basket', gen_random_uuid(), pg_temp.ana())$$),
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 10000.01, 'load', gen_random_uuid(), pg_temp.ana())$$),
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), -1, 'load', gen_random_uuid(), pg_temp.ana())$$),
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 3, 'piece', gen_random_uuid(), pg_temp.ana())$$),
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 3, 'load', gen_random_uuid(), pg_temp.ana(), repeat('x', 281))$$),
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 3, 'load', null, pg_temp.ana())$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}',
  'rejects: basket without allow_basket_estimates, qty > 10,000, negative, piece, note > 280, no client_id');
select is(array[pg_temp.run_as('ownerB', $$select public.record_soil_estimate(pg_temp.id('gTowel'), 1, 'basket', gen_random_uuid(), null)$$),
                pg_temp.run_as('ownerB', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 1, 'basket', gen_random_uuid(), null)$$),
                pg_temp.run_as('ownerB', $$select public.record_soil_estimate(gen_random_uuid(), 1, 'basket', gen_random_uuid(), null)$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}', 'no oracle: plant A group with / without baskets vs a missing group → NOT_AUTHORIZED for owner B');
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('groupA2'), 1, 'load', gen_random_uuid(), pg_temp.ana())$$),
  'NOT_AUTHORIZED', 'same org, other plant: the plant A manager is not authorized on plant A2');
select is((select count(*)::int from public.staff_sessions where plant_id = pg_temp.id('plantA') and consumed_at is not null), 0,
  'entries no longer consume staff sessions');

-- ══ record_finished_goods (E1) ════════════════════════════════════════════
select is(pg_temp.writes($$select public.record_finished_goods(pg_temp.id('mat'), 0, 5, gen_random_uuid(), pg_temp.ana(), p_occurred_at => pg_temp.ny('2026-11-03 11:30'))$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'record_finished_goods: owner/manager with a staff session only (a lead or viewer cannot write finished goods)');
select is(pg_temp.val_as('manager', $$select row(r.packs, r.pack_size_used, r.loose_pieces, r.pieces, r.warning, r.duplicate)::text
                                       from public.record_finished_goods(pg_temp.id('napkin'), 7, 34, pg_temp.cid(10), pg_temp.ana(), p_occurred_at => pg_temp.ny('2026-11-03 11:30')) r$$),
  '(7,100,34,734,,f)', 'pack item: 7 × 100 + 34 = 734 pieces (generated); no warning');
select is(pg_temp.val_as('manager', $$select row(r.pack_size_used, r.pieces, r.warning)::text
                                       from public.record_finished_goods(pg_temp.id('napkin'), 2, 60, gen_random_uuid(), pg_temp.ana(), 50, p_occurred_at => pg_temp.ny('2026-11-03 11:30')) r$$),
  '(50,160,LOOSE_EXCEEDS_PACK)', 'per-entry pack size override 50; warning when loose ≥ pack size');
select is(pg_temp.val_as('manager', $$select (public.record_finished_goods(pg_temp.id('napkin'), 7, 34, pg_temp.cid(10), null)).duplicate$$),
  'true', 'idempotent retry (no session needed for an entry already saved)');
select is((select count(*)::int from public.finished_goods_entries where client_id = pg_temp.cid(10)), 1, 'one row');
select is((select array[area_id::text, coalesce(staff_id::text, 'none'), entered_by::text, source::text] from public.finished_goods_entries where client_id = pg_temp.cid(10)),
  array[pg_temp.id('fin')::text, 'none', pg_temp.id('manager')::text, 'manual'],
  'area defaults to the plant''s finishing area; no staff; entered_by = the account');
select is(array[
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 1, 0, gen_random_uuid(), pg_temp.ana())$$),
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 3, gen_random_uuid(), pg_temp.ana(), 10)$$)],
  '{COUNT_MODE_MISMATCH,COUNT_MODE_MISMATCH}', 'unit items: no packs, no pack size');
select is(array[
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 0, gen_random_uuid(), pg_temp.ana())$$),
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 100001, gen_random_uuid(), pg_temp.ana())$$),
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('napkin'), 10001, 0, gen_random_uuid(), pg_temp.ana())$$),
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('napkin'), 1, 0, gen_random_uuid(), pg_temp.ana(), 0)$$),
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 1, gen_random_uuid(), pg_temp.ana(), p_shift_choice => 'later')$$),
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 1, gen_random_uuid(), pg_temp.ana(), p_area_id => pg_temp.id('wash'))$$),
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 1, gen_random_uuid(), pg_temp.ana(), p_station_id => gen_random_uuid())$$),
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 1, gen_random_uuid(), pg_temp.ana(), p_queue_item_id => 'e0000000-0000-0000-0000-0000000000b1')$$),
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 1, gen_random_uuid(), pg_temp.ana(), p_note => repeat('n', 141))$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}',
  'rejects: nothing counted, loose > 100,000, packs > 10,000, pack size 0, bad shift choice, washroom area, unknown station, foreign queue item, note > 140');
select is(array[
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 1, gen_random_uuid(), pg_temp.ana(), p_occurred_at => now() + interval '10 minutes')$$),
  pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 1, gen_random_uuid(), pg_temp.ana(), p_occurred_at => now() - interval '31 days')$$)],
  '{OUT_OF_RANGE_TIMESTAMP,OUT_OF_RANGE_TIMESTAMP}', 'occurred_at: at most 5 min ahead, 30 days back');
select is(pg_temp.run_as('manager', $$select public.record_finished_goods(pg_temp.id('mat'), 0, 1, gen_random_uuid(), null)$$),
  '1', 'finished goods need no name + PIN any more (null session id)');

-- Shift attribution (2026-11-07): the area's shift at occurred_at, not the (ignored) PIN person's home shift
-- (Ana's home shift is finishing Evening; it no longer matters).
select is(pg_temp.val_as('manager', $$select (public.record_finished_goods(pg_temp.id('mat'), 0, 2, gen_random_uuid(), pg_temp.ana(), p_shift_choice => 'my', p_occurred_at => pg_temp.ny('2026-11-03 01:00'))).shift_instance_id$$),
  pg_temp.si(pg_temp.id('fin'), 'Night', '2026-11-03')::text, '"My shift" at 01:00: the finishing shift running at 01:00 (Night), not Ana''s Evening');
select is(pg_temp.val_as('manager', $$select (public.record_finished_goods(pg_temp.id('mat'), 0, 2, gen_random_uuid(), pg_temp.ana(), p_shift_choice => 'next', p_occurred_at => pg_temp.ny('2026-11-03 01:00'))).shift_instance_id$$),
  pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03')::text, '"Next shift": the finishing instance after that one');
select set_config('test.s6', pg_temp.sess('manager', 'b0000000-0000-0000-0000-0000000000a2', '1470')::text, true);
select is(pg_temp.val_as('manager', $$select (public.record_finished_goods(pg_temp.id('mat'), 0, 2, gen_random_uuid(), current_setting('test.s6')::uuid, p_occurred_at => pg_temp.ny('2026-11-03 11:30'))).shift_instance_id$$),
  pg_temp.si(pg_temp.id('fin'), 'Day', '2026-11-03')::text, 'no home shift: the area''s clock-based shift');
select set_config('test.s7', pg_temp.sess('manager', 'b0000000-0000-0000-0000-0000000000a2', '1470')::text, true);
select is(pg_temp.val_as('manager', $$select row(r.shift_instance_id, r.production_date)::text from public.record_finished_goods(pg_temp.id('mat'), 0, 2, gen_random_uuid(), current_setting('test.s7')::uuid, p_occurred_at => pg_temp.ny('2026-11-01 13:00')) r$$),
  '(,2026-11-01)', 'off-shift (Sunday, no shift): no instance; production_date stored (security carry-forward)');

-- No oracle.
select is(array[pg_temp.run_as('ownerB', $$select public.record_finished_goods(pg_temp.id('mat'), 1, 0, gen_random_uuid(), null)$$),
                pg_temp.run_as('ownerB', $$select public.record_finished_goods(pg_temp.id('napkin'), 1, 0, gen_random_uuid(), null)$$),
                pg_temp.run_as('ownerB', $$select public.record_finished_goods(gen_random_uuid(), 1, 0, gen_random_uuid(), null)$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}', 'no oracle: plant A unit item vs pack item vs missing item → NOT_AUTHORIZED (count mode not revealed)');
select is(pg_temp.run_as('ownerB', $$select public.record_finished_goods(pg_temp.id('itemB'), 0, 1, gen_random_uuid(), (public.start_staff_session('b0000000-0000-0000-0000-0000000000a1', '2580')).staff_session_id)$$),
  'NOT_AUTHORIZED', 'owner B cannot confirm plant A staff');

-- ══ void_finished_goods (E4) ══════════════════════════════════════════════
-- The entry id is looked up as postgres: since 2026-11-05 managers read only the current shift's rows.
select set_config('test.f10', (select id::text from public.finished_goods_entries where client_id = pg_temp.cid(10)), true);
select is(array[pg_temp.run_as('lead', $$select public.void_finished_goods(current_setting('test.f10')::uuid, 'typo')$$),
                pg_temp.run_as('viewer', $$select public.void_finished_goods(current_setting('test.f10')::uuid, 'typo')$$),
                pg_temp.run_as('display', $$select public.void_finished_goods(current_setting('test.f10')::uuid, 'typo')$$),
                pg_temp.run_as('ownerB', $$select public.void_finished_goods(current_setting('test.f10')::uuid, 'typo')$$),
                pg_temp.run_as('ownerB', $$select public.void_finished_goods(gen_random_uuid(), 'typo')$$),
                pg_temp.run_as('anon', $$select public.void_finished_goods(gen_random_uuid(), 'typo')$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'void: lead, viewer, display, other tenant (foreign or missing id) denied');
select is(pg_temp.run_as('manager', $$select public.void_finished_goods(current_setting('test.f10')::uuid, '  ')$$),
  'VALIDATION_FAILED', 'a reason is required');
select is(pg_temp.val_as('manager', $$select row(r.void_reason, r.duplicate, r.pieces)::text from public.void_finished_goods(current_setting('test.f10')::uuid, 'counted twice') r$$),
  '("counted twice",f,734)', 'manager voids with a reason');
select is(pg_temp.val_as('owner', $$select (public.void_finished_goods(current_setting('test.f10')::uuid, 'again')).duplicate$$),
  'true', 'voiding again is idempotent');
select is((select array[(voided_by = pg_temp.id('manager'))::text, void_reason] from public.finished_goods_entries where client_id = pg_temp.cid(10)),
  array['true', 'counted twice'], 'the first void stands');
select is((select coalesce(sum(pieces), 0)::int from public.finished_by_shift where item_type_id = pg_temp.id('napkin')), 160,
  'voided entries leave the totals (734 voided, 160 left)');
select is((select count(*)::int from public.finished_goods_entries where client_id = pg_temp.cid(10)), 1, 'voided, never deleted');
select is((select count(*)::int from public.audit_log where action = 'finished_goods_entries.void' and plant_id = pg_temp.id('plantA')
              and entity_id = current_setting('test.f10')::uuid), 1, 'the void is audited');
select is(pg_temp.run_as('manager', $$update public.finished_goods_entries set voided_at = null where client_id = pg_temp.cid(10)$$), '42501',
  'clients cannot un-void (no UPDATE privilege)');

-- ══ Who-entered is attribution only ══════════════════════════════════════
select is((select count(*)::int from information_schema.columns where table_schema = 'public' and table_name in ('finished_by_shift', 'washroom_by_shift', 'daily_reconciliation')
            and column_name in ('staff_id', 'entered_by', 'entered_by_name')), 0, 'report views carry no per-person column');
select is((select count(*)::int from public.staff_sessions where plant_id = pg_temp.id('plantA') and auth_user_id <> pg_temp.id('manager') and auth_user_id <> pg_temp.id('owner') and auth_user_id <> pg_temp.id('lead')), 0,
  'sessions belong to the confirming accounts only');

select * from finish();
rollback;
