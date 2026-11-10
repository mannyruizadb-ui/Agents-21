-- Owner decisions 2026-11-10 (migrations 20261110153114_restrict_item_edits_and_stock and
-- 20261110153115_add_wash_group_second_color):
-- 1. item_types insert/update: OWNER only (manager, lead, viewer, display, other tenant, anon cannot).
-- 2. item_types.stock_qty: no client SELECT (every role, owner included, gets 42501 on the column); the owner
--    reads it via get_item_stock(plant), writes it with a plain UPDATE (no RETURNING of stock_qty);
--    finished_goods_over_stock(item, total) → boolean for owner/manager only; no view / RPC leaks it.
-- 3. wash_groups.color_hex_2: format CHECK, owner-only; queue_board / get_queue / get_washroom_board /
--    get_wash_group_pace return it; app.apply_wash_group_colors data.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(56);

-- First column / value per role, or the error (val_as), in matrix order.
create function pg_temp.vals(p_sql text) returns text[] language sql as $$
  select array_agg(coalesce(pg_temp.val_as(u, p_sql), 'null') order by o)
    from unnest(array['owner','manager','lead','viewer','display','display_nodev','ownerB','anon'])
         with ordinality as r(u, o);
$$;

-- ══ 1. Items: owner-only writes ═════════════════════════════════════════
select is(pg_temp.writes($$update public.item_types set name = 'Napkin' where id = pg_temp.id('napkin')$$),
  '{1,0,0,0,0,0,0,42501}', 'item name: owner only (a manager''s update matches no row)');
select is(array[
  pg_temp.run_as('manager', $$update public.item_types set pack_size = 50 where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('manager', $$update public.item_types set color_hex = '#123456' where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('manager', $$update public.item_types set name_i18n = '{"es":"X"}' where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('manager', $$update public.item_types set active = false where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('manager', $$update public.item_types set pieces_per_load = 1 where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('manager', $$update public.item_types set sort_order = 9 where id = pg_temp.id('napkin')$$)],
  '{0,0,0,0,0,0}', 'a manager edits nothing on an item: pack size, colour, translations, active, pieces per load, order');
select is((select row(name, pack_size, color_hex, active, pieces_per_load, sort_order)::text from public.item_types where id = pg_temp.id('napkin')),
  (select row('Napkin', 100, color_hex, true, 500.00, sort_order)::text from public.item_types where id = pg_temp.id('napkin')),
  'the napkin is unchanged after the manager''s attempts (pack 100, active, 500 pcs/load)');
select is(pg_temp.writes($$insert into public.item_types (org_id, plant_id, wash_group_id, name, category)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('gMat'), 'I-' || substr(md5(random()::text), 1, 8), 'other')$$),
  '{1,42501,42501,42501,42501,42501,42501,42501}', 'item insert: owner only');
select is((select array_agg(polname::text || ':' || pg_get_expr(coalesce(polwithcheck, polqual), polrelid) order by polname)
             from pg_policy where polrelid = 'public.item_types'::regclass and polcmd in ('a', 'w')),
  array['item_types_insert:( SELECT app.has_role(item_types.plant_id, ''{owner}''::app.member_role[]) AS has_role)',
        'item_types_update:( SELECT app.has_role(item_types.plant_id, ''{owner}''::app.member_role[]) AS has_role)'],
  'item_types insert / update policies: {owner}');
select is(pg_temp.reads($$select id, name, pack_size, bin_size, color_hex from public.item_types where plant_id = pg_temp.id('plantA')$$),
  '{4,4,4,4,4,0,0,42501}', 'reading items (named columns, no stock) is unchanged for every plant role and the display');

-- ══ 2. stock_qty: owner-only ════════════════════════════════════════════
update public.item_types set stock_qty = 77 where id = pg_temp.id('napkin');   -- service role
select ok(not has_column_privilege('authenticated', 'public.item_types', 'stock_qty', 'select')
          and not has_column_privilege('anon', 'public.item_types', 'stock_qty', 'select')
          and not has_table_privilege('authenticated', 'public.item_types', 'select'),
  'no client SELECT on stock_qty (and no table-level SELECT that would include it)');
select is((select coalesce(array_agg(attname::text order by attnum), '{}') from pg_attribute
            where attrelid = 'public.item_types'::regclass and attnum > 0 and not attisdropped
              and not has_column_privilege('authenticated', 'public.item_types', attname, 'select')),
  '{stock_qty}', 'every other item column stays selectable by authenticated');
select ok(has_column_privilege('authenticated', 'public.item_types', 'stock_qty', 'update')
          and has_column_privilege('authenticated', 'public.item_types', 'stock_qty', 'insert'),
  'the column UPDATE / INSERT grants stay (the owner writes stock directly; RLS limits it to the owner)');
select is(pg_temp.reads($$select stock_qty from public.item_types where plant_id = pg_temp.id('plantA')$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'stock_qty: no role reads the column directly (owner included: use get_item_stock)');
select is(pg_temp.reads($$select * from public.item_types where plant_id = pg_temp.id('plantA')$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'select * is refused for every role (clients list columns)');
select is(pg_temp.reads($$select id from public.item_types where stock_qty > 5$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'no filter on stock_qty either (no WHERE oracle)');
select is(array[
  pg_temp.run_as('owner', $$update public.item_types set stock_qty = 80 where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('owner', $$update public.item_types set stock_qty = 81, sort_order = sort_order where id = pg_temp.id('napkin') returning id$$),
  pg_temp.run_as('owner', $$update public.item_types set stock_qty = 82 where id = pg_temp.id('napkin') returning stock_qty$$),
  pg_temp.run_as('owner', $$update public.item_types set stock_qty = stock_qty + 1 where id = pg_temp.id('napkin')$$),
  pg_temp.run_as('manager', $$update public.item_types set stock_qty = 1 where id = pg_temp.id('napkin')$$)],
  '{1,1,42501,42501,0}',
  'owner writes stock with a plain UPDATE (return=minimal, or RETURNING other columns); RETURNING / reading stock_qty is refused; a manager matches no row');
select is((select stock_qty from public.item_types where id = pg_temp.id('napkin')), 81, 'the owner''s last allowed write landed (81)');

-- get_item_stock
select is(pg_temp.reads($$select * from public.get_item_stock(pg_temp.id('plantA'))$$),
  '{4,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'get_item_stock: owner of the plant only (every item, active or not); anon has no execute');
select is(pg_temp.val_as('owner', $$select array_agg(item_type_id::text || '=' || coalesce(stock_qty::text, 'null') order by item_type_id)::text
                                     from public.get_item_stock(pg_temp.id('plantA')) where item_type_id in (pg_temp.id('napkin'), pg_temp.id('mat'))$$),
  format('{%s=81,%s=null}', pg_temp.id('napkin'), pg_temp.id('mat')), 'the owner gets the number (81) and null for unknown stock');
select is(array[pg_temp.run_as('ownerB', $$select * from public.get_item_stock(pg_temp.id('plantA'))$$),
                pg_temp.run_as('owner', $$select * from public.get_item_stock(pg_temp.id('plantB'))$$),
                pg_temp.run_as('owner', $$select * from public.get_item_stock(null)$$),
                pg_temp.run_as('owner', $$select * from public.get_item_stock(gen_random_uuid())$$),
                pg_temp.run_as('owner', $$select * from public.get_item_stock(pg_temp.id('plantA2'))$$, true)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,1}',
  'get_item_stock: no cross-tenant read, null / unknown plant refused; an org-wide owner reads another plant of the org');

-- finished_goods_over_stock
select is(pg_temp.vals($$select public.finished_goods_over_stock(pg_temp.id('napkin'), 82)::text$$),
  '{true,true,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'over_stock: owner and manager of the item''s plant only (lead, viewer, display, other tenant, anon refused)');
select is(array[pg_temp.val_as('manager', $$select public.finished_goods_over_stock(pg_temp.id('napkin'), 82)::text$$),
                pg_temp.val_as('manager', $$select public.finished_goods_over_stock(pg_temp.id('napkin'), 81)::text$$),
                pg_temp.val_as('manager', $$select public.finished_goods_over_stock(pg_temp.id('napkin'), 0)::text$$),
                pg_temp.val_as('manager', $$select public.finished_goods_over_stock(pg_temp.id('mat'), 1000000)::text$$)],
  '{true,false,false,false}', 'over_stock: true above stock, false at / below it, false when stock is unknown (null)');
select is(array[pg_temp.val_as('manager', $$select public.finished_goods_over_stock(pg_temp.id('napkin'), -1)::text$$),
                pg_temp.val_as('manager', $$select public.finished_goods_over_stock(pg_temp.id('napkin'), null)::text$$),
                pg_temp.val_as('manager', $$select public.finished_goods_over_stock(gen_random_uuid(), 5)::text$$),
                pg_temp.val_as('manager', $$select public.finished_goods_over_stock(null, 5)::text$$),
                pg_temp.val_as('ownerB', $$select public.finished_goods_over_stock(pg_temp.id('napkin'), 5)::text$$),
                pg_temp.val_as('manager', $$select public.finished_goods_over_stock(pg_temp.id('itemB'), 5)::text$$),
                pg_temp.val_as('lead', $$select public.finished_goods_over_stock(pg_temp.id('napkin'), -1)::text$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}',
  'over_stock: negative / null total refused; unknown item, other tenant refused; the role check comes before argument checks');
select is(pg_temp.val_as('manager', $$select pg_typeof(public.finished_goods_over_stock(pg_temp.id('napkin'), 1))::text$$), 'boolean',
  'over_stock returns only a boolean (never the number)');

-- No other path returns stock.
select is((select coalesce(array_agg(p.proname::text order by p.proname), '{}') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prosrc ilike '%stock_qty%'),
  '{finished_goods_over_stock,get_item_stock}', 'only get_item_stock (owner) and finished_goods_over_stock (boolean) read stock_qty among API functions');
select is((select count(*)::int from information_schema.view_column_usage where table_schema = 'public' and table_name = 'item_types' and column_name = 'stock_qty'),
  0, 'no view uses stock_qty');
select ok(not exists (select 1 from pg_publication_tables where schemaname = 'public' and tablename = 'item_types'),
  'item_types is not in a realtime publication');
select is(array[pg_temp.val_as('owner', $$select (public.get_finished_goods_shift(pg_temp.id('fin')))::text !~* 'stock'$$),
                pg_temp.val_as('manager', $$select (public.get_finished_goods_shift(pg_temp.id('fin')))::text !~* 'stock'$$)],
  '{true,true}', 'get_finished_goods_shift returns no stock (owner or manager)');
select ok(pg_get_functiondef('public.get_finished_goods_shift(uuid)'::regprocedure) !~* 'stock',
  'get_finished_goods_shift does not read stock at all');
select is(array[pg_temp.run_as('manager', $$select 1 from public.audit_log where entity = 'item_types' and after ? 'stock_qty'$$, true),
                pg_temp.run_as('lead', $$select 1 from public.audit_log where entity = 'item_types' and after ? 'stock_qty'$$, true),
                pg_temp.run_as('viewer', $$select 1 from public.audit_log where entity = 'item_types' and after ? 'stock_qty'$$, true),
                pg_temp.run_as('display', $$select 1 from public.audit_log where entity = 'item_types' and after ? 'stock_qty'$$, true)],
  '{0,0,0,0}', 'item audit images (which carry stock_qty) stay owner-only');
select ok(pg_temp.run_as('owner', $$select 1 from public.audit_log where entity = 'item_types' and after ? 'stock_qty'$$, true)::int > 0,
  'the owner still sees item audit rows');
select ok((select bool_and(p.prosecdef and 'search_path=""' = any(p.proconfig)
                          and not has_function_privilege('anon', p.oid, 'execute')
                          and has_function_privilege('authenticated', p.oid, 'execute'))
             from pg_proc p where p.oid in ('public.get_item_stock(uuid)'::regprocedure, 'public.finished_goods_over_stock(uuid, integer)'::regprocedure)),
  'both stock RPCs: security definer, search_path '''', authenticated only');

-- ══ 3. wash_groups.color_hex_2 ══════════════════════════════════════════
select is(array[(select is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'wash_groups' and column_name = 'color_hex_2'),
                (select data_type from information_schema.columns where table_schema = 'public' and table_name = 'wash_groups' and column_name = 'color_hex_2')],
  '{YES,text}', 'wash_groups.color_hex_2: nullable text (null = single colour)');
select is(pg_temp.writes($$update public.wash_groups set color_hex_2 = '#DC2626' where id = pg_temp.id('gNapkin')$$),
  '{1,0,0,0,0,0,0,42501}', 'color_hex_2 edit: owner only');
select is(pg_temp.writes($$insert into public.wash_groups (org_id, plant_id, name, color_hex, color_hex_2)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'G-' || substr(md5(random()::text), 1, 8), '#15803D', '#DC2626')$$),
  '{1,42501,42501,42501,42501,42501,42501,42501}', 'insert with a second colour: owner only');
select is(pg_temp.run_as('ownerB', $$update public.wash_groups set color_hex_2 = '#000000' where id = pg_temp.id('gNapkin')$$), '0',
  'cross-tenant: owner B cannot set plant A''s second colour');
select is(array[
  pg_temp.run_as('owner', $$update public.wash_groups set color_hex_2 = 'DC2626' where id = pg_temp.id('gNapkin')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set color_hex_2 = '#DC262' where id = pg_temp.id('gNapkin')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set color_hex_2 = '#GGGGGG' where id = pg_temp.id('gNapkin')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set color_hex_2 = '' where id = pg_temp.id('gNapkin')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set color_hex_2 = '#DC2626 ' where id = pg_temp.id('gNapkin')$$),
  pg_temp.as_service($$update public.wash_groups set color_hex_2 = 'red' where id = pg_temp.id('gNapkin')$$)],
  '{23514,23514,23514,23514,23514,23514}', 'CHECK rejects a colour without #, 5 digits, non-hex, empty, trailing space (service role too)');
select is(array[
  pg_temp.run_as('owner', $$update public.wash_groups set color_hex_2 = null where id = pg_temp.id('gNapkin')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set color_hex_2 = '#abcdef' where id = pg_temp.id('gNapkin')$$),
  pg_temp.run_as('owner', $$update public.wash_groups set color_hex_2 = '#DC2626' where id = pg_temp.id('gNapkin')$$)],
  '{1,1,1}', 'null and #RRGGBB (either case) pass');
select ok(exists (select 1 from public.audit_log where entity = 'wash_groups' and entity_id = pg_temp.id('gNapkin') and after ->> 'color_hex_2' = '#DC2626'),
  'color_hex_2 edits are audited');
update public.wash_groups set color_hex_2 = '#1D4ED8' where id = pg_temp.id('gTowel');

-- Screens: an open washroom queue item (Towels) and a running Napkins cycle on Washer 1.
insert into public.queue_items (id, org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position, created_by, client_id) values
  ('e0000000-0000-0000-0000-0000000231a1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gTowel'), pg_temp.id('towel'), 2, 'load', 1, pg_temp.id('manager'), gen_random_uuid());
insert into public.washer_cycles (org_id, plant_id, area_id, wash_group_id, machine_id, started_at, load_count, source, entered_by, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), pg_temp.id('machine'), now() - interval '5 minutes', 1, 'manual', pg_temp.id('lead'), gen_random_uuid());

select is((select array_agg(attname::text order by attnum) from pg_attribute where attrelid = 'public.queue_board'::regclass and attnum > 28),
  '{loads_remaining,wash_group_color_hex_2}', 'queue_board: wash_group_color_hex_2 appended after loads_remaining');
select is(pg_temp.vals($$select wash_group_color_hex_2 from public.queue_board where id = 'e0000000-0000-0000-0000-0000000231a1'$$),
  '{#1D4ED8,#1D4ED8,#1D4ED8,#1D4ED8,#1D4ED8,"null","null",42501}', 'queue_board carries the second colour (RLS unchanged: display of the area sees it)');
select is(pg_temp.vals($$select wash_group_color_hex || '/' || wash_group_color_hex_2 from public.get_queue(pg_temp.id('wash')) where id = 'e0000000-0000-0000-0000-0000000231a1'$$),
  (select array_fill(color_hex || '/#1D4ED8', array[5]) || array['NOT_AUTHORIZED', 'NOT_AUTHORIZED', '42501']
     from public.wash_groups where id = pg_temp.id('gTowel')),
  'get_queue returns wash_group_color_hex_2 to every role that reads the queue (and the washroom display)');
select is((select (proargnames)[array_length(proargnames, 1) - 2:array_length(proargnames, 1)]::text from pg_proc where oid = 'public.get_queue(uuid)'::regprocedure),
  '{created_by_name,from_estimate,wash_group_color_hex_2}', 'get_queue: wash_group_color_hex_2 appended last');
select is(pg_temp.vals($$select wash_group_color_hex_2 || '/' || next_wash_group_color_hex_2 from public.get_washroom_board(pg_temp.id('wash')) where machine_id = pg_temp.id('machine')$$),
  '{#DC2626/#1D4ED8,#DC2626/#1D4ED8,#DC2626/#1D4ED8,#DC2626/#1D4ED8,#DC2626/#1D4ED8,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'get_washroom_board: current group (Napkins) and NEXT group (Towels) second colours, for the board''s readers');
select is((select (proargnames)[array_length(proargnames, 1) - 2:array_length(proargnames, 1)]::text from pg_proc where oid = 'public.get_washroom_board(uuid)'::regprocedure),
  '{down_reason_label_i18n,wash_group_color_hex_2,next_wash_group_color_hex_2}', 'get_washroom_board: the two columns appended last');
select is(pg_temp.val_as('owner', $$select color_hex_2 from public.get_wash_group_pace(pg_temp.id('plantA')) where wash_group_id = pg_temp.id('gNapkin')$$),
  '#DC2626', 'get_wash_group_pace (owner) returns color_hex_2');
select is(pg_temp.run_as('manager', $$select * from public.get_wash_group_pace(pg_temp.id('plantA'))$$), 'NOT_AUTHORIZED',
  'get_wash_group_pace stays owner-only after the re-create');
select is((select (proargnames)[array_length(proargnames, 1) - 1:array_length(proargnames, 1)]::text from pg_proc where oid = 'public.get_wash_group_pace(uuid, date)'::regprocedure),
  '{server_time,color_hex_2}', 'get_wash_group_pace: color_hex_2 appended last');
select ok((select bool_and(p.prosecdef and 'search_path=""' = any(p.proconfig)
                          and not has_function_privilege('anon', p.oid, 'execute')
                          and has_function_privilege('authenticated', p.oid, 'execute')
                          and obj_description(p.oid, 'pg_proc') like '%2026-11-10%')
             from pg_proc p where p.oid in ('public.get_queue(uuid)'::regprocedure, 'public.get_washroom_board(uuid)'::regprocedure,
                                            'public.get_wash_group_pace(uuid, date)'::regprocedure)),
  're-created board functions: security definer, search_path '''', authenticated only, comment updated');
select ok((select reloptions @> '{security_invoker=true}' from pg_class where oid = 'public.queue_board'::regclass),
  'queue_board is still security_invoker');

-- ══ 3b. DATA: app.apply_wash_group_colors (ADB seed / migration) ════════
create function pg_temp.adb_pair(p_name text, p_customer text) returns text language sql stable as $$
  select g.color_hex || '/' || coalesce(g.color_hex_2, '-')
    from public.wash_groups g
    join public.plants p on p.id = g.plant_id and p.name = 'Miami'
    join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
    left join public.customers c on c.id = g.customer_id
   where g.name = p_name and c.name is not distinct from p_customer;
$$;
select is(array[pg_temp.adb_pair('Napkins – Green & Red', null), pg_temp.adb_pair('Red & blue tablecloths', null),
                pg_temp.adb_pair('Napkins – Bone & Chambray', null), pg_temp.adb_pair('Colored napkins', 'AA Linen'),
                pg_temp.adb_pair('Colored tablecloths', 'AA Linen')],
  '{#15803D/#DC2626,#DC2626/#1D4ED8,#E7DCC4/#8FA9C8,#DC2626/#1D4ED8,#DC2626/#1D4ED8}',
  'ADB two-colour groups (ours and AA Linen''s) at the owner''s colours');
select is(array[pg_temp.adb_pair('Napkins – Navy Blue w/ Stripe', null), pg_temp.adb_pair('Napkins – Pink', null)],
  '{#1E3A8A/-,#EC4899/-}', 'single-colour napkin groups match their items (Navy Blue w/ Stripe #1E3A8A, Pink #EC4899)');
select is((select count(*)::int from public.wash_groups g join public.plants p on p.id = g.plant_id and p.name = 'Miami' where g.color_hex_2 is not null),
  5, 'exactly 5 ADB groups have a second colour');
select is((select app.apply_wash_group_colors(p.id)::text from public.plants p where p.name = 'Miami'),
  '{"groups": 0, "targets_not_found": 0}', 'apply_wash_group_colors is idempotent on ADB (all 7 targets found, nothing left to change)');
-- On fixture plant A: a hyphen, case and doubled spaces still match; another plant's / a customer's same-named group does not.
insert into public.wash_groups (id, org_id, plant_id, name, color_hex) values
  ('71000000-0000-0000-0000-000000231a01', pg_temp.id('orgA'), pg_temp.id('plantA'), 'napkins -  GREEN & red', '#000001'),
  ('71000000-0000-0000-0000-000000231b01', pg_temp.id('orgB'), pg_temp.id('plantB'), 'Napkins – Green & Red', '#000002');
select is((select app.apply_wash_group_colors(pg_temp.id('plantA'))::text), '{"groups": 1, "targets_not_found": 6}',
  'fixture plant: the one matching group recoloured, the 6 other targets reported missing');
select is(array[(select color_hex || '/' || color_hex_2 from public.wash_groups where id = '71000000-0000-0000-0000-000000231a01'),
                (select color_hex || '/' || coalesce(color_hex_2, '-') from public.wash_groups where id = '71000000-0000-0000-0000-000000231b01')],
  '{#15803D/#DC2626,#000002/-}', 'name match ignores case, doubled spaces and – / -; plant B untouched');
select throws_ok($$select app.apply_wash_group_colors(gen_random_uuid())$$, 'P0001', 'VALIDATION_FAILED', 'unknown plant refused');
select ok(not has_function_privilege('authenticated', 'app.apply_wash_group_colors(uuid)', 'execute')
          and not has_function_privilege('anon', 'app.apply_wash_group_colors(uuid)', 'execute'),
  'apply_wash_group_colors is not callable by clients');
select ok((select string_agg(m[1], ' ') from regexp_matches(pg_get_functiondef('app.apply_wash_group_colors(uuid)'::regprocedure),
                                                             'raise notice ([^;]*);', 'gi') m) !~* 'name|customer|jsonb_agg',
  'the NOTICE (public deploy log) carries counts only, never names');

select * from finish();
rollback;
