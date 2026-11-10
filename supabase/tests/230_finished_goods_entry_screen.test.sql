-- Finished-goods entry screen (owner 2026-11-10):
-- 1. item_types.bin_size / stock_qty: owner-only (app.guard_item_owner_fields), CHECK ranges; pack size changes
--    never alter past entries; app.apply_sheet_bin_sizes.
-- 2. get_finished_goods_shift(area): role matrix, current-shift entries only, voided excluded, totals, no names,
--    off-shift → last ended instance (entries owner-only, owner rule 2026-11-05).
-- 3. Fabric colours: app.fabric_item_color / app.fabric_group_color / app.apply_fabric_colors on inserted rows.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(52);

-- ══ 1. item_types.bin_size / stock_qty ═══════════════════════════════════
select has_column('public', 'item_types', 'bin_size', 'item_types.bin_size exists');
select has_column('public', 'item_types', 'stock_qty', 'item_types.stock_qty exists');
select is(array[(select is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'item_types' and column_name = 'bin_size'),
                (select data_type from information_schema.columns where table_schema = 'public' and table_name = 'item_types' and column_name = 'bin_size'),
                (select is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'item_types' and column_name = 'stock_qty'),
                (select data_type from information_schema.columns where table_schema = 'public' and table_name = 'item_types' and column_name = 'stock_qty')],
  '{YES,integer,YES,integer}', 'bin_size and stock_qty: nullable integers (null = no bin quick-add / unknown stock)');

select is(pg_temp.writes($$update public.item_types set bin_size = coalesce(bin_size, 0) + 1 where id = pg_temp.id('napkin')$$),
  '{1,NOT_AUTHORIZED,0,0,0,0,0,42501}', 'bin_size: owner only (manager NOT_AUTHORIZED; lead/viewer/display/other tenant match no row; anon denied)');
select is(pg_temp.writes($$update public.item_types set stock_qty = coalesce(stock_qty, 0) + 10 where id = pg_temp.id('napkin')$$),
  '{1,NOT_AUTHORIZED,0,0,0,0,0,42501}', 'stock_qty: owner only');
select is((select row(bin_size, stock_qty)::text from public.item_types where id = pg_temp.id('napkin')), '(1,10)',
  'only the owner''s edits landed');
select is(pg_temp.run_as('owner', $$update public.item_types set bin_size = null, stock_qty = null where id = pg_temp.id('napkin')$$), '1',
  'owner can clear both back to null');
select is(pg_temp.run_as('manager', $$update public.item_types set pack_size = 100, sort_order = 5 where id = pg_temp.id('napkin')$$), '1',
  'a manager still edits the other item fields (PRD §4.7 item_types U = owner, manager; unchanged)');
select is(pg_temp.run_as('manager', $$update public.item_types set pack_size = 100, bin_size = null where id = pg_temp.id('napkin')$$), '1',
  'a manager''s edit that leaves bin_size as it is passes');

select is(array[
  pg_temp.run_as('owner', $$update public.item_types set name = 'Napkin', name_i18n = '{"es":"Servilleta"}', color_hex = '#FFFFFF', pack_size = 100,
                                bin_size = 500, stock_qty = 20000, pieces_per_load = 500, pieces_per_load_source = 'counted', sort_order = 1, active = true
                            where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('owner', $$update public.item_types set color_hex = '#000000' where id = pg_temp.id('mat')$$)],
  '{1,1}', 'owner updates name, name_i18n, color_hex, pack_size, bin_size, stock_qty, pieces_per_load, sort_order, active');
select is(pg_temp.run_as('owner', $$update public.item_types set bin_size = 5 where id = pg_temp.id('itemB')$$), '0',
  'cross-tenant: org A''s owner cannot touch plant B''s item');

-- Inserts: setting either column is owner-only too.
select is(array[
  pg_temp.run_as('manager', $$insert into public.item_types (org_id, plant_id, wash_group_id, name, category, count_mode, pack_size, bin_size)
                              values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 'Mgr sheet', 'linen', 'pack', 10, 500)$$),
  pg_temp.run_as('manager', $$insert into public.item_types (org_id, plant_id, wash_group_id, name, category, count_mode, pack_size, stock_qty)
                              values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 'Mgr sheet', 'linen', 'pack', 10, 9)$$),
  pg_temp.run_as('manager', $$insert into public.item_types (org_id, plant_id, wash_group_id, name, category, count_mode, pack_size)
                              values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 'Mgr sheet', 'linen', 'pack', 10)$$),
  pg_temp.run_as('owner', $$insert into public.item_types (org_id, plant_id, wash_group_id, name, category, count_mode, pack_size, bin_size, stock_qty)
                            values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 'Owner sheet', 'linen', 'pack', 10, 500, 3000)$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,1,1}', 'insert: a manager cannot set bin_size / stock_qty (without them it still works); the owner can');

-- CHECK ranges.
select is(array[
  pg_temp.run_as('owner', $$update public.item_types set bin_size = 0 where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('owner', $$update public.item_types set bin_size = 5001 where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('owner', $$update public.item_types set bin_size = -500 where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('owner', $$update public.item_types set stock_qty = -1 where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('owner', $$update public.item_types set stock_qty = 10000001 where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('owner', $$update public.item_types set color_hex = 'FFFFFF' where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('owner', $$update public.item_types set color_hex = '#FFF' where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('owner', $$update public.item_types set pack_size = 0 where id = pg_temp.id('napkin')$$)],
  '{23514,23514,23514,23514,23514,23514,23514,23514}', 'CHECKs reject bin_size 0 / 5001 / negative, stock_qty −1 / 10,000,001, a bad colour, pack_size 0');
select is(array[
  pg_temp.run_as('owner', $$update public.item_types set bin_size = 1, stock_qty = 0 where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('owner', $$update public.item_types set bin_size = 5000, stock_qty = 10000000 where id = pg_temp.id('napkin')$$)],
  '{1,1}', 'CHECK bounds are inclusive (bin 1–5,000; stock 0–10,000,000)');
select is(pg_temp.as_service($$update public.item_types set bin_size = 0 where id = pg_temp.id('napkin')$$), '23514',
  'the service role is held to the same CHECK');
select ok(not has_function_privilege('authenticated', 'app.guard_item_owner_fields()', 'execute')
          and not has_function_privilege('anon', 'app.guard_item_owner_fields()', 'execute'),
  'app.guard_item_owner_fields is not callable by clients');
select ok(exists (select 1 from public.audit_log where entity = 'item_types' and entity_id = pg_temp.id('napkin')
                    and after ? 'bin_size'),
  'bin_size edits are audited (item_types audit trigger)');

-- ══ 2. get_finished_goods_shift ══════════════════════════════════════════
-- Finishing 2: a past, the current and the next instance around now(). Finishing 3: off-shift now, its last
-- instance ended 3 h ago (an older one ended 27 h ago).
insert into public.areas (id, org_id, plant_id, name, kind) values
  ('30000000-0000-0000-0000-0000000000f2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Finishing 2', 'finishing'),
  ('30000000-0000-0000-0000-0000000000f3', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Finishing 3', 'finishing');
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week) values
  ('90000000-0000-0000-0000-0000000f0001', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f2', 'Past', '00:00', '01:00', '{0}'),
  ('90000000-0000-0000-0000-0000000f0002', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f2', 'Now',  '02:00', '03:00', '{0}'),
  ('90000000-0000-0000-0000-0000000f0003', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f2', 'Next', '04:00', '05:00', '{0}'),
  ('90000000-0000-0000-0000-0000000f0004', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f3', 'Late', '00:00', '01:00', '{0}'),
  ('90000000-0000-0000-0000-0000000f0005', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f3', 'Old',  '02:00', '03:00', '{0}');
delete from public.shift_instances where area_id in ('30000000-0000-0000-0000-0000000000f2', '30000000-0000-0000-0000-0000000000f3');
insert into public.shift_instances (id, org_id, plant_id, area_id, shift_id, business_date, starts_at, ends_at) values
  ('91000000-0000-0000-0000-0000000f0001', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f2', '90000000-0000-0000-0000-0000000f0001', '2026-01-01', now() - interval '20 hours', now() - interval '12 hours'),
  ('91000000-0000-0000-0000-0000000f0002', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f2', '90000000-0000-0000-0000-0000000f0002', '2026-01-01', now() - interval '2 hours', now() + interval '6 hours'),
  ('91000000-0000-0000-0000-0000000f0003', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f2', '90000000-0000-0000-0000-0000000f0003', '2026-01-01', now() + interval '6 hours', now() + interval '14 hours'),
  ('91000000-0000-0000-0000-0000000f0004', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f3', '90000000-0000-0000-0000-0000000f0004', '2026-01-01', now() - interval '11 hours', now() - interval '3 hours'),
  ('91000000-0000-0000-0000-0000000f0005', pg_temp.id('orgA'), pg_temp.id('plantA'), '30000000-0000-0000-0000-0000000000f3', '90000000-0000-0000-0000-0000000f0005', '2025-12-31', now() - interval '35 hours', now() - interval '27 hours');

-- record_finished_goods as p_user in p_area at now() − p_ago; returns the entry id (or the error).
create function pg_temp.fg(p_user text, p_area uuid, p_item text, p_packs int, p_loose int, p_ago interval, p_choice text default 'own')
returns text language sql as $$
  select pg_temp.val_as(p_user, format($q$select (public.record_finished_goods(pg_temp.id(%L), %s, %s, gen_random_uuid(), null, p_shift_choice => %L,
                                                   p_area_id => %L::uuid, p_occurred_at => now() - %L::interval)).id::text$q$,
                                       p_item, p_packs, p_loose, p_choice, p_area, p_ago));
$$;
create temp table fx (k text primary key, id uuid);
-- Napkin pack size 100 (set above); fixture Towel / Mat are unit items.
insert into fx values
  ('cur_napkin_packs', pg_temp.fg('manager', '30000000-0000-0000-0000-0000000000f2', 'napkin', 2, 5, '90 minutes')::uuid),   -- 205
  ('cur_towel',        pg_temp.fg('manager', '30000000-0000-0000-0000-0000000000f2', 'towel', 0, 7, '60 minutes')::uuid),    -- 7
  ('cur_napkin_loose', pg_temp.fg('owner',   '30000000-0000-0000-0000-0000000000f2', 'napkin', 0, 30, '30 minutes')::uuid),  -- 30
  ('cur_mat_voided',   pg_temp.fg('manager', '30000000-0000-0000-0000-0000000000f2', 'mat', 0, 3, '20 minutes')::uuid),      -- voided below
  ('past_napkin',      pg_temp.fg('owner',   '30000000-0000-0000-0000-0000000000f2', 'napkin', 1, 0, '15 hours')::uuid),     -- past shift
  ('next_towel',       pg_temp.fg('manager', '30000000-0000-0000-0000-0000000000f2', 'towel', 0, 1, '0', 'next')::uuid),     -- next shift
  ('late_mat',         pg_temp.fg('owner',   '30000000-0000-0000-0000-0000000000f3', 'mat', 0, 4, '5 hours')::uuid),         -- f3 last ended
  ('old_mat',          pg_temp.fg('owner',   '30000000-0000-0000-0000-0000000000f3', 'mat', 0, 9, '30 hours')::uuid);        -- f3 older
select is(pg_temp.run_as('manager', format($$select public.void_finished_goods(%L, 'typo')$$, (select id from fx where k = 'cur_mat_voided'))), '1',
  'fixture: one current-shift entry voided');

-- Pack size changes never alter past entries (pack_size_used is stored per entry; pieces is generated).
select is(pg_temp.run_as('owner', $$update public.item_types set pack_size = 50 where id = pg_temp.id('napkin')$$), '1',
  'owner changes the napkin pack size 100 → 50');
select is((select row(f.packs, f.pack_size_used, f.loose_pieces, f.pieces)::text from public.finished_goods_entries f
            where f.id = (select id from fx where k = 'cur_napkin_packs')),
  '(2,100,5,205)', 'the earlier entry keeps pack_size_used 100 and pieces 205');

-- Role matrix.
select is(pg_temp.writes($$select public.get_finished_goods_shift('30000000-0000-0000-0000-0000000000f2')$$),
  '{1,1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'get_finished_goods_shift: owner, manager, lead; viewer, displays, other tenant NOT_AUTHORIZED; anon cannot execute');
select is(array[
  pg_temp.run_as('owner', $$select public.get_finished_goods_shift(pg_temp.id('washB'))$$),
  pg_temp.run_as('ownerB', $$select public.get_finished_goods_shift(pg_temp.id('fin'))$$),
  pg_temp.run_as('manager', $$select public.get_finished_goods_shift(gen_random_uuid())$$),
  pg_temp.run_as('manager', $$select public.get_finished_goods_shift(null)$$),
  pg_temp.run_as('nobody', $$select public.get_finished_goods_shift(pg_temp.id('fin'))$$),
  pg_temp.run_as('a2viewer', $$select public.get_finished_goods_shift(pg_temp.id('fin'))$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}',
  'cross-tenant, unknown / null area, no membership: the same NOT_AUTHORIZED');
select is(pg_temp.run_as('manager', $$select public.get_finished_goods_shift(pg_temp.id('wash'))$$), 'VALIDATION_FAILED',
  'a washroom area is refused (VALIDATION_FAILED)');
select ok((select p.prosecdef and p.proconfig @> array['search_path=""'] from pg_proc p where p.oid = 'public.get_finished_goods_shift(uuid)'::regprocedure)
          and not has_function_privilege('anon', 'public.get_finished_goods_shift(uuid)', 'execute'),
  'security definer, search_path empty, not executable by anon');

-- Current shift content (manager's view).
create function pg_temp.r(p_user text, p_area uuid, p_expr text) returns text language sql as $$
  select pg_temp.val_as(p_user, format($q$select (%s)::text from (select public.get_finished_goods_shift(%L::uuid) as r) x$q$, p_expr, p_area));
$$;
select is(pg_temp.r('manager', '30000000-0000-0000-0000-0000000000f2',
                    $$r->>'is_current' || ' ' || (r->>'entries_hidden') || ' ' || (r->'shift'->>'id') || ' ' || (r->'shift'->>'name')$$),
  'true false 91000000-0000-0000-0000-0000000f0002 Now', 'the CURRENT instance, is_current true');
select is(pg_temp.r('manager', '30000000-0000-0000-0000-0000000000f2', $$(select array_agg(k order by k) from jsonb_object_keys(r) k)$$),
  '{area_id,as_of,entries,entries_hidden,is_current,shift,totals}', 'top-level keys');
select is(pg_temp.r('manager', '30000000-0000-0000-0000-0000000000f2', $$(select array_agg(k order by k) from jsonb_object_keys(r->'shift') k)$$),
  '{ends_at,id,name,production_date,starts_at}', 'shift keys');
select is(pg_temp.r('manager', '30000000-0000-0000-0000-0000000000f2', $$(select array_agg(k order by k) from jsonb_object_keys(r->'entries'->0) k)$$),
  '{client_id,id,item_type_id,loose_pieces,occurred_at,pack_size_used,packs,pieces}', 'entry keys: no entered_by, staff_id, voided_by or note');
select is(pg_temp.r('manager', '30000000-0000-0000-0000-0000000000f2',
                    format($$r::text like '%%%s%%' or r::text like '%%%s%%' or r::text ~ 'entered_by|staff_id|voided_by'$$, pg_temp.id('manager'), pg_temp.id('owner'))),
  'false', 'no user id or name field anywhere in the result');
select is(pg_temp.r('manager', '30000000-0000-0000-0000-0000000000f2', $$(select array_agg((e->>'id')::uuid order by o) from jsonb_array_elements(r->'entries') with ordinality t(e, o))$$),
  (select array[(select id from fx where k = 'cur_napkin_packs'), (select id from fx where k = 'cur_towel'),
                (select id from fx where k = 'cur_napkin_loose')]::text), 'current-shift, non-voided entries only (not the voided one, the past or the next shift)');
select is(pg_temp.r('manager', '30000000-0000-0000-0000-0000000000f2', $$(select string_agg(e->>'pieces', ',' order by o) from jsonb_array_elements(r->'entries') with ordinality t(e, o))$$),
  '205,7,30', 'entries ordered by occurred_at, pieces from the generated column');
select is(pg_temp.r('manager', '30000000-0000-0000-0000-0000000000f2', $$r->'entries'->0$$)::jsonb - 'id' - 'client_id' - 'occurred_at',
  jsonb_build_object('item_type_id', pg_temp.id('napkin'), 'packs', 2, 'pack_size_used', 100, 'loose_pieces', 5, 'pieces', 205),
  'an entry carries packs, pack_size_used (as entered), loose_pieces and pieces');
select is(pg_temp.r('manager', '30000000-0000-0000-0000-0000000000f2', $$r->'totals'$$)::jsonb,
  jsonb_build_array(jsonb_build_object('item_type_id', pg_temp.id('towel'), 'pieces', 7, 'entries', 1),
                    jsonb_build_object('item_type_id', pg_temp.id('napkin'), 'pieces', 235, 'entries', 2)),
  'totals per item, by item sort_order (towel 0, napkin 1 set above): towel 7 (1), napkin 205 + 30 = 235 (2); the voided mat is not counted');
select is(pg_temp.r('lead', '30000000-0000-0000-0000-0000000000f2', $$jsonb_array_length(r->'entries')$$), '3',
  'a lead reads the same current-shift entries');
select is(pg_temp.r('owner', '30000000-0000-0000-0000-0000000000f2', $$jsonb_array_length(r->'entries')$$), '3',
  'the owner too (current shift)');

-- Off shift: the most recent ended instance; its entries are owner-only.
select is(pg_temp.r('owner', '30000000-0000-0000-0000-0000000000f3',
                    $$r->>'is_current' || ' ' || (r->>'entries_hidden') || ' ' || (r->'shift'->>'id') || ' ' || (r->'totals'->0->>'pieces')$$),
  'false false 91000000-0000-0000-0000-0000000f0004 4', 'off shift, owner: the last ENDED instance (not the older one) with its entries');
select is(pg_temp.r('manager', '30000000-0000-0000-0000-0000000000f3',
                    $$r->>'is_current' || ' ' || (r->>'entries_hidden') || ' ' || (r->'shift'->>'id') || ' ' || (r->'entries')::text || ' ' || (r->'totals')::text$$),
  'false true 91000000-0000-0000-0000-0000000f0004 [] []', 'off shift, manager: the header only, entries hidden (owner rule 2026-11-05)');
select is(pg_temp.r('lead', '30000000-0000-0000-0000-0000000000f3', $$(r->>'entries_hidden') || ' ' || jsonb_array_length(r->'entries')$$),
  'true 0', 'off shift, lead: entries hidden too');
select is(pg_temp.r('manager', pg_temp.id('spare'),
                    $$r->>'is_current' || ' ' || (r->>'entries_hidden') || ' ' || jsonb_typeof(r->'shift') || ' ' || (r->'entries')::text$$),
  'false false null []', 'an area that never had a shift: shift null, nothing hidden, no entries');
update public.shift_instances set skipped_at = now() where id = '91000000-0000-0000-0000-0000000f0002';
select is(pg_temp.r('owner', '30000000-0000-0000-0000-0000000000f2', $$r->>'is_current' || ' ' || (r->'shift'->>'id')$$),
  'false 91000000-0000-0000-0000-0000000f0001', 'a skipped instance is not current: the last ended one is returned');
update public.shift_instances set skipped_at = null where id = '91000000-0000-0000-0000-0000000f0002';

-- ══ 3. Fabric colours ════════════════════════════════════════════════════
select is(array[app.fabric_item_color('Napkin – Dark Navy Blue w/ Stripe'), app.fabric_item_color('Napkin – Navy Blue w/ Stripe'),
                app.fabric_item_color('Napkin – Navy Blue'), app.fabric_item_color('Napkin – Black w/ Stripe'),
                app.fabric_item_color('Napkin – Cotton Black'), app.fabric_item_color('napkin  -  regular white'),
                app.fabric_item_color('Tablecloth 120" round white'), app.fabric_item_color('Tablecloth 132" round black'),
                app.fabric_item_color('Tablecloth 62×62 bone'), app.fabric_item_color('Napkin – Chambray'),
                app.fabric_item_color('Napkin – Green'), app.fabric_item_color('Tablecloth 62×62 red'),
                app.fabric_item_color('Napkin – Pink'), app.fabric_item_color('Tablecloth 62×62 blue'),
                app.fabric_item_color('Sheet – old')],
  '{#172554,#1E3A8A,#1E3A8A,#000000,#000000,#FFFFFF,#FFFFFF,#000000,#E7DCC4,#8FA9C8,#15803D,#DC2626,#EC4899,#1D4ED8,#FFFFFF}',
  'item fabric colours (longest ending first; case, spaces and - / – ignored)');
select is(array[app.fabric_item_color('Napkin – Blue'), app.fabric_item_color('Mechanic towel – white'), app.fabric_item_color('Apron black'),
                app.fabric_item_color('Napkin – Teal'), app.fabric_item_color(null)],
  '{NULL,NULL,NULL,NULL,NULL}', 'no rule: a blue napkin (tablecloths only), towels, aprons, unknown colours, null');
select is(array[app.fabric_group_color('Stained white napkins'), app.fabric_group_color('Coats (white)'), app.fabric_group_color('White aprons'),
                app.fabric_group_color('New sheets'), app.fabric_group_color('Old sheets'), app.fabric_group_color('Napkins – Regular White'),
                app.fabric_group_color('Black mats'), app.fabric_group_color('Napkins – Black w/ Stripe'), app.fabric_group_color('COLORED MATS')],
  '{#FFFFFF,#FFFFFF,#FFFFFF,#FFFFFF,#FFFFFF,#FFFFFF,#000000,#000000,#DC2626}', 'group colours: white / sheets, black, Colored mats red');
select is(array[app.fabric_group_color('Colored napkins'), app.fabric_group_color('Napkins – Green & Red'), app.fabric_group_color('Red & blue tablecloths'),
                app.fabric_group_color('Brito mats'), app.fabric_group_color('Charcoal mats'), app.fabric_group_color('Kitchen towels'),
                app.fabric_group_color('Black & white aprons'), app.fabric_group_color('Whitewash')],
  '{NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL}', 'groups left alone: mixed / unsure, Brito, Charcoal, towels, both white and black, not a whole word');

-- apply_fabric_colors on inserted rows (plant A; plant B untouched).
insert into public.customers (id, org_id, plant_id, name) values
  ('72000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'AA Test');
insert into public.wash_groups (id, org_id, plant_id, name, color_hex, customer_id) values
  ('71000000-0000-0000-0000-00000000c001', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Black mats',            '#1F1F1F', null),
  ('71000000-0000-0000-0000-00000000c002', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Colored mats',          '#B45309', null),
  ('71000000-0000-0000-0000-00000000c003', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Brito mats',            '#EF4444', null),
  ('71000000-0000-0000-0000-00000000c004', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Stained white napkins', '#9333EA', '72000000-0000-0000-0000-0000000000a1'),
  ('71000000-0000-0000-0000-00000000c005', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Colored napkins',       '#A21CAF', '72000000-0000-0000-0000-0000000000a1'),
  ('71000000-0000-0000-0000-00000000c006', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Old sheets',            '#cbd5e1', null),
  ('71000000-0000-0000-0000-00000000c007', pg_temp.id('orgB'), pg_temp.id('plantB'), 'White napkins',         '#15803D', null);
insert into public.item_types (id, org_id, plant_id, wash_group_id, name, category, count_mode, pack_size, color_hex) values
  ('70000000-0000-0000-0000-00000000c001', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 'Napkin – Navy Blue w/ Stripe', 'linen', 'pack', 100, '#64748B'),
  ('70000000-0000-0000-0000-00000000c002', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 'Tablecloth 120" round white', 'linen', 'unit', null, '#64748B'),
  ('70000000-0000-0000-0000-00000000c003', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 'Sheet – old', 'linen', 'pack', 10, '#64748B'),
  ('70000000-0000-0000-0000-00000000c004', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gTowel'),  'Mechanic towel – white', 'towel', 'pack', 100, '#64748B'),
  ('70000000-0000-0000-0000-00000000c005', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 'Sheet – new', 'linen', 'pack', 10, '#64748B'),
  ('70000000-0000-0000-0000-00000000c006', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gNapkin'), 'Sheet – regular', 'linen', 'pack', 10, '#64748B'),
  ('70000000-0000-0000-0000-00000000c007', pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('groupB'),  'Napkin – Black', 'linen', 'pack', 100, '#64748B');
select is((app.apply_fabric_colors(pg_temp.id('plantA')) - 'groups_unchanged' - 'linen_items_unchanged')::text,
  '{"items": 5, "groups": 4}', 'apply_fabric_colors: 5 items (the fixture "Napkin" has no colour rule) and 4 groups changed');
select is(array(select color_hex from public.wash_groups where id::text like '71000000-0000-0000-0000-00000000c00%' order by id),
  '{#000000,#DC2626,#EF4444,#FFFFFF,#A21CAF,#FFFFFF,#15803D}',
  'groups: Black mats #000000, Colored mats red, Brito kept, AA stained white #FFFFFF, Colored napkins kept, Old sheets #FFFFFF, plant B untouched');
select is(array(select color_hex from public.item_types where id::text like '70000000-0000-0000-0000-00000000c00%' order by id),
  '{#1E3A8A,#FFFFFF,#FFFFFF,#64748B,#FFFFFF,#FFFFFF,#64748B}',
  'items: navy stripe, round white, sheets #FFFFFF; the mechanic towel (not linen) and plant B untouched');
select is((app.apply_fabric_colors(pg_temp.id('plantA')) - 'groups_unchanged' - 'linen_items_unchanged')::text,
  '{"items": 0, "groups": 0}', 'a re-run changes nothing (idempotent)');
select ok((app.apply_fabric_colors(pg_temp.id('plantA'))->'groups_unchanged') @> '[{"name": "Colored napkins", "customer": "AA Test"}, {"name": "Brito mats"}]',
  'the result lists the groups left unchanged (with their customer)');

-- apply_sheet_bin_sizes: new / regular → 500 when null; an owner's value and old sheets are kept.
update public.item_types set bin_size = 450 where id = '70000000-0000-0000-0000-00000000c006';
select is(app.apply_sheet_bin_sizes(pg_temp.id('plantA'))::text, '{"set": 1}', 'apply_sheet_bin_sizes sets one row');
select is(array(select coalesce(bin_size::text, 'none') from public.item_types where id in ('70000000-0000-0000-0000-00000000c003',
                  '70000000-0000-0000-0000-00000000c005', '70000000-0000-0000-0000-00000000c006') order by id),
  '{none,500,450}', 'Sheet – old null, Sheet – new 500, Sheet – regular keeps the owner''s 450');
select ok(not has_function_privilege('authenticated', 'app.apply_fabric_colors(uuid)', 'execute')
          and not has_function_privilege('authenticated', 'app.apply_sheet_bin_sizes(uuid)', 'execute')
          and not has_function_privilege('authenticated', 'app.fabric_item_color(text)', 'execute')
          and not has_function_privilege('anon', 'app.fabric_group_color(text)', 'execute'),
  'the data functions are not callable by clients');

select * from finish();
rollback;
