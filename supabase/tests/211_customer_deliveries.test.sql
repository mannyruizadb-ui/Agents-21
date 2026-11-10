-- Outside-customer deliveries (owner 2026-11-06, B): record_customer_delivery (owner/manager; no name + PIN
-- since 2026-11-07: the session id is ignored, staff_id null),
-- lines of the customer's own groups, one queue item per line at the bottom of the washroom queue,
-- idempotency, append-only tables, the owner-only read, and the customer_delivery alert.
begin;
\ir _fixtures.psql
-- The entry-PIN RPCs are service_role only since 20261110104605 (asserted in 229_audit_fixes_2026_11_10).
-- This file still exercises their kept-for-history logic as signed-in roles: grant inside this rolled-back transaction.
grant execute on function public.start_staff_session(uuid, text) to authenticated;
select plan(38);

insert into public.entry_staff (id, org_id, plant_id, display_name, pin_hash) values
  ('b0000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Ben', extensions.crypt('1470', extensions.gen_salt('bf')));
insert into public.customers (id, org_id, plant_id, name, name_i18n) values
  ('c1000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'AA Test', '{"es":"AA Prueba"}'),
  ('c1000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Other Co', '{}'),
  ('c1000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Gone Co', '{}'),
  ('c1000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), 'B Customer', '{}');
update public.customers set active = false where id = 'c1000000-0000-0000-0000-0000000000a3';
insert into public.wash_groups (id, org_id, plant_id, customer_id, name, loads_per_bin, allow_bin_estimates, active) values
  ('71000000-0000-0000-0000-0000000aa0a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1', 'Kitchen towels', 1.5, true, true),
  ('71000000-0000-0000-0000-0000000aa0a2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1', 'Aprons', null, false, true),
  ('71000000-0000-0000-0000-0000000aa0a3', pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1', 'Old stuff', null, false, false),
  ('71000000-0000-0000-0000-0000000aa0a4', pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a2', 'Other towels', null, false, true),
  ('71000000-0000-0000-0000-0000000aa0b1', pg_temp.id('orgB'), pg_temp.id('plantB'), 'c1000000-0000-0000-0000-0000000000b1', 'B towels', null, false, true);
create function pg_temp.c(p text) returns uuid language sql immutable as $$
  select (case p when 'aa' then 'c1000000-0000-0000-0000-0000000000a1'
                 when 'aa2' then 'c1000000-0000-0000-0000-0000000000a2'
                 when 'gone' then 'c1000000-0000-0000-0000-0000000000a3'
                 when 'b' then 'c1000000-0000-0000-0000-0000000000b1'
                 when 'gKT' then '71000000-0000-0000-0000-0000000aa0a1'
                 when 'gAp' then '71000000-0000-0000-0000-0000000aa0a2'
                 when 'gOld' then '71000000-0000-0000-0000-0000000aa0a3'
                 when 'gOther' then '71000000-0000-0000-0000-0000000aa0a4'
                 when 'gB' then '71000000-0000-0000-0000-0000000aa0b1' end)::uuid;
$$;
create function pg_temp.ben() returns uuid language sql as $$
  select (public.start_staff_session('b0000000-0000-0000-0000-0000000000a2', '1470')).staff_session_id;
$$;
-- record_customer_delivery for plant A / AA with p_lines, a client id and Ben's PIN.
create function pg_temp.rec(p_lines text, p_client uuid default gen_random_uuid(), p_customer text default 'aa') returns text language sql as $$
  select format($q$select public.record_customer_delivery(pg_temp.id('plantA'), pg_temp.c(%L), %L::jsonb, %L, pg_temp.ben())$q$,
                p_customer, p_lines, p_client);
$$;
grant execute on function pg_temp.c(text), pg_temp.ben(), pg_temp.rec(text, uuid, text) to authenticated, anon;

-- An open normal item and a RUSH item already in the queue.
select pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 2, 'load', 'e1000000-0000-0000-0000-000000000001', pg_temp.id('gNapkin'))$$);
select pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', 'e1000000-0000-0000-0000-000000000002', pg_temp.id('gMat'), p_is_rush => true)$$);

-- ══ Structure ════════════════════════════════════════════════════════════
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('public.customer_deliveries'::regclass, 'public.customer_delivery_lines'::regclass)),
  'customer_deliveries / customer_delivery_lines: RLS enabled');
select is(pg_temp.reads($$select * from public.customer_deliveries$$), '{42501,42501,42501,42501,42501,42501,42501,42501}',
  'customer_deliveries: RPC-only (no client grants for any role)');
select is(pg_temp.reads($$select * from public.customer_delivery_lines$$), '{42501,42501,42501,42501,42501,42501,42501,42501}',
  'customer_delivery_lines: RPC-only (no client grants for any role)');

-- ══ Role matrix (role check first; empty lines so nothing is written) ═════
select is(pg_temp.writes($$select public.record_customer_delivery(pg_temp.id('plantA'), pg_temp.c('aa'), '[]', gen_random_uuid(), null)$$),
  '{VALIDATION_FAILED,VALIDATION_FAILED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'record_customer_delivery: owner or manager pass the role check (no PIN needed) and reach validation; lead, viewer, display, other tenant refused; anon cannot call');
select is(pg_temp.run_as('ownerB', $$select public.record_customer_delivery(pg_temp.id('plantA'), pg_temp.c('b'), '[]', gen_random_uuid(), null)$$),
  'NOT_AUTHORIZED', 'another tenant learns nothing (role check before any validation)');
select is(pg_temp.run_as('manager', $$select public.record_customer_delivery(gen_random_uuid(), pg_temp.c('aa'), '[]', gen_random_uuid(), null)$$),
  'NOT_AUTHORIZED', 'unknown plant: NOT_AUTHORIZED');

-- ══ A manager records a delivery ═════════════════════════════════════════
select is(pg_temp.val_as('manager', format('select row((r).queue_item_ids is not null, cardinality((r).queue_item_ids), (r).duplicate)::text from (%s) x(r)',
            pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":2.5},{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a2","bins":0.25}]',
                        'd1000000-0000-0000-0000-000000000001'))),
  '(t,2,f)', 'a manager with name + PIN records a delivery of 2 groups: 2 queue items, not a duplicate');
select is((select row(d.customer_id = pg_temp.c('aa'), d.entered_by = pg_temp.id('manager'), d.staff_id is null,
                      abs(extract(epoch from d.delivered_at - now())) < 1, d.voided_at is null)::text
             from public.customer_deliveries d where d.client_id = 'd1000000-0000-0000-0000-000000000001'),
  '(t,t,t,t,t)', 'the delivery: customer, entered_by = the account, no staff (the PIN session id was ignored), delivered_at = now, not voided');
select is((select array_agg(row(l.line_no, l.bins, coalesce(l.loads::text, 'null'))::text order by l.line_no)
             from public.customer_delivery_lines l join public.customer_deliveries d on d.id = l.delivery_id
            where d.client_id = 'd1000000-0000-0000-0000-000000000001'),
  array['(1,2.50,3.750)', '(2,0.25,null)'], 'lines: bins, loads = app.to_loads (2.5 bins × 1.5), null without a bin factor (never guessed)');
select is((select array_agg(row(q.wash_group_id = l.wash_group_id, q.unit, q.qty, q.customer_id = pg_temp.c('aa'), q.is_rush, q.is_rewash,
                                q.assigned_machine_id is null, q.area_id = pg_temp.id('wash'), q.status, q.created_by = pg_temp.id('manager'))::text order by l.line_no)
             from public.customer_delivery_lines l
             join public.customer_deliveries d on d.id = l.delivery_id
             join public.queue_items q on q.id = l.queue_item_id
            where d.client_id = 'd1000000-0000-0000-0000-000000000001'),
  array['(t,bin,2.50,t,f,f,t,t,queued,t)', '(t,bin,0.25,t,f,f,t,t,queued,t)'],
  'one washroom queue item per line: unit bin, qty = bins, customer AA, normal (not rush / rewash / assigned)');
select is((select array_agg(q.wash_group_id order by q.is_rush desc, q.position) from public.queue_items q
            where q.area_id = pg_temp.id('wash') and q.status in ('queued', 'in_progress')),
  array[pg_temp.id('gMat'), pg_temp.id('gNapkin'), pg_temp.c('gKT'), pg_temp.c('gAp')],
  'the delivery''s items are at the BOTTOM of the queue, in line order (rush first, then normal work)');

-- ══ Idempotency ══════════════════════════════════════════════════════════
select set_config('test.d1', (select row(d.id, (select array_agg(l.queue_item_id order by l.line_no) from public.customer_delivery_lines l where l.delivery_id = d.id), true)::public.customer_delivery_result::text
                               from public.customer_deliveries d where d.client_id = 'd1000000-0000-0000-0000-000000000001'), true);
select is(pg_temp.val_as('manager', $$select public.record_customer_delivery(pg_temp.id('plantA'), pg_temp.c('aa'),
                                       '[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":9}]',
                                       'd1000000-0000-0000-0000-000000000001', null, p_entered_at => now() - interval '9 hours')::text$$),
  current_setting('test.d1'),
  'a retry with the same client_id returns the saved delivery (duplicate = true; before the window and the session)');
select is(array[(select count(*)::int from public.customer_deliveries), (select count(*)::int from public.queue_items where customer_id = pg_temp.c('aa')),
                (select count(*)::int from public.alert_events where kind = 'customer_delivery')],
  array[1, 2, 1], 'the retry wrote nothing: no second delivery, queue item or alert');
select is(pg_temp.run_as('ownerB', $$select public.record_customer_delivery(pg_temp.id('plantB'), pg_temp.c('b'),
                                     '[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0b1","bins":1}]', 'd1000000-0000-0000-0000-000000000001', null,
                                     p_entered_at => now() - interval '9 hours')$$),
  'OUT_OF_RANGE_TIMESTAMP', 'another plant''s client_id is independent (unique per plant, 2026-11-07): no "already used" answer, the call goes on to the time-window check');

-- ══ Validation (nothing is written) ══════════════════════════════════════
select is(array[
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a4","bins":1}]')),
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000000a1","bins":1}]')),
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0b1","bins":1}]')),
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a3","bins":1}]')),
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a4","bins":1}]', p_customer => 'aa2') ),
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0b1","bins":1}]', p_customer => 'b')),
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":1}]', p_customer => 'gone'))],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,1,VALIDATION_FAILED,VALIDATION_FAILED}',
  'lines must be active groups of THIS customer (not another customer''s, not ours, not another tenant''s, not inactive); the customer must be an active one of the plant');
select is(array[
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":0.3}]')),
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":0}]')),
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":50.25}]')),
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":"2"}]')),
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1"}]')),
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"not-a-uuid","bins":1}]')),
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":1,"qty":3}]')),
  pg_temp.run_as('manager', pg_temp.rec('[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":1},{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":2}]')),
  pg_temp.run_as('manager', pg_temp.rec('[]')),
  pg_temp.run_as('manager', pg_temp.rec('{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":1}')),
  pg_temp.run_as('manager', pg_temp.rec((select jsonb_agg(jsonb_build_object('wash_group_id', pg_temp.c('gKT'), 'bins', 1)) from generate_series(1, 31))::text)),
  pg_temp.run_as('manager', pg_temp.rec('[1]'))],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}',
  'bins 0.25–50 in quarters (numbers only), each line {wash_group_id, bins} once, 1–30 lines in an array');
select is(array[
  pg_temp.run_as('manager', $$select public.record_customer_delivery(pg_temp.id('plantA'), pg_temp.c('aa'), '[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":1}]', gen_random_uuid(), pg_temp.ben(), p_entered_at => now() - interval '6 hours 1 minute')$$),
  pg_temp.run_as('manager', $$select public.record_customer_delivery(pg_temp.id('plantA'), pg_temp.c('aa'), '[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":1}]', gen_random_uuid(), pg_temp.ben(), p_entered_at => now() + interval '2 minutes')$$),
  pg_temp.run_as('manager', $$select public.record_customer_delivery(pg_temp.id('plantA'), pg_temp.c('aa'), '[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":1}]', gen_random_uuid(), pg_temp.ben(), p_note => repeat('x', 201))$$),
  pg_temp.run_as('manager', $$select public.record_customer_delivery(pg_temp.id('plantA'), pg_temp.c('aa'), '[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":1}]', null, pg_temp.ben())$$)],
  '{OUT_OF_RANGE_TIMESTAMP,OUT_OF_RANGE_TIMESTAMP,VALIDATION_FAILED,VALIDATION_FAILED}',
  'delivered_at within [now − 6 h, now + 1 min]; note ≤ 200; client_id required');
select is(array[(select count(*)::int from public.customer_deliveries), (select count(*)::int from public.customer_delivery_lines)],
  array[2, 3], 'rejected deliveries wrote nothing (only the valid Other Co delivery was added)');
select is(pg_temp.run_as('owner', $$select public.record_customer_delivery(pg_temp.id('plantA'), pg_temp.c('aa'), '[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a2","bins":4}]',
                                    'd1000000-0000-0000-0000-000000000002', pg_temp.ben(), p_note => 'Two bins wet', p_entered_at => now() - interval '2 hours')$$),
  '1', 'an owner records a delivery too (offline entry from 2 hours ago, with a note)');
select is((select array[count(*), count(staff_id)]::int[] from public.customer_deliveries), '{3,0}',
  'no delivery carries a staff person (2026-11-07: the account is the attribution)');

-- ══ Append-only and the line trigger (service role) ══════════════════════
select is(array[
  pg_temp.as_service($$update public.customer_delivery_lines set bins = 3 where line_no = 1$$),
  pg_temp.as_service($$delete from public.customer_delivery_lines where line_no = 1$$),
  pg_temp.as_service($$delete from public.customer_deliveries where client_id = 'd1000000-0000-0000-0000-000000000001'$$),
  pg_temp.as_service($$update public.customer_deliveries set note = 'changed' where client_id = 'd1000000-0000-0000-0000-000000000001'$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}', 'append-only: lines never change, deliveries are never deleted or edited');
select is(array[
  pg_temp.as_service($$update public.customer_deliveries set voided_at = now(), voided_by = pg_temp.id('owner'), void_reason = 'wrong customer' where client_id = 'd1000000-0000-0000-0000-000000000002'$$),
  pg_temp.as_service($$update public.customer_deliveries set voided_at = now(), voided_by = pg_temp.id('owner'), void_reason = 'again' where client_id = 'd1000000-0000-0000-0000-000000000002'$$),
  pg_temp.as_service($$update public.customer_deliveries set voided_at = now() where client_id = 'd1000000-0000-0000-0000-000000000001'$$)],
  '{1,VALIDATION_FAILED,23514}', 'a delivery can be voided once, with who and why (the RPC void_customer_delivery is tested in 219)');
select is(array[
  pg_temp.as_service($$insert into public.customer_delivery_lines (org_id, plant_id, delivery_id, line_no, wash_group_id, bins)
                        select org_id, plant_id, id, 9, pg_temp.c('gOther'), 1 from public.customer_deliveries where client_id = 'd1000000-0000-0000-0000-000000000001'$$),
  pg_temp.as_service($$insert into public.customer_delivery_lines (org_id, plant_id, delivery_id, line_no, wash_group_id, bins)
                        select org_id, plant_id, id, 9, pg_temp.c('gKT'), 0.3 from public.customer_deliveries where client_id = 'd1000000-0000-0000-0000-000000000001'$$),
  pg_temp.as_service($$insert into public.customer_delivery_lines (org_id, plant_id, delivery_id, line_no, wash_group_id, bins)
                        select org_id, plant_id, id, 9, pg_temp.c('gKT'), 1 from public.customer_deliveries where client_id = 'd1000000-0000-0000-0000-000000000001'$$),
  pg_temp.as_service($$insert into public.customer_delivery_lines (org_id, plant_id, delivery_id, line_no, wash_group_id, bins, loads)
                        select org_id, plant_id, id, 8, pg_temp.c('gKT'), 1, 99 from public.customer_deliveries where client_id = 'd1000000-0000-0000-0000-000000000002'$$)],
  '{VALIDATION_FAILED,23514,23505,1}', 'the line trigger: only the delivery''s customer''s groups, bins in quarters, a group once per delivery');
select is((select loads from public.customer_delivery_lines where line_no = 8), 1.500,
  'loads is always computed (a client value is overwritten: 1 bin × 1.5)');
select is((select count(*)::int from public.audit_log where entity in ('customer_deliveries', 'customer_delivery_lines')
             and (after ? 'entered_by' or after ? 'staff_id' or after ? 'voided_by')), 0,
  'deliveries are audited without who-entered columns');

-- ══ get_customer_deliveries: owner only ══════════════════════════════════
select is(pg_temp.reads($$select * from public.get_customer_deliveries(pg_temp.id('plantA'))$$),
  '{3,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'get_customer_deliveries: owner only (managers see a delivery''s work in the queue)');
select is(pg_temp.val_as('owner', $$select string_agg(customer_name || ':' || entered_by_name || ':' || voided || ':' || jsonb_array_length(lines), ',' order by voided, customer_name)
                                    from public.get_customer_deliveries(pg_temp.id('plantA'))$$),
  'AA Test:Manager A:false:2,Other Co:Manager A:false:1,AA Test:Owner A:true:2',
  'rows: customer, who entered (the account''s name, owner screens only), voided, lines');
select is(pg_temp.val_as('owner', $$select (lines -> 0 ->> 'wash_group_name') || '/' || (lines -> 0 ->> 'bins') || '/' || (lines -> 0 ->> 'loads') || '/' || (lines -> 0 ->> 'queue_status')
                                    from public.get_customer_deliveries(pg_temp.id('plantA')) where note is null and customer_name = 'AA Test'$$),
  'Kitchen towels/2.50/3.750/queued', 'a line: group, bins, loads, its queue item''s status');
select is(pg_temp.val_as('owner', $$select count(*) from public.get_customer_deliveries(pg_temp.id('plantA'), p_customer_id => pg_temp.c('aa2'))$$),
  '1', 'p_customer_id filters one customer');
select pg_temp.as_service($$insert into public.customer_deliveries (org_id, plant_id, customer_id, delivered_at, entered_by, client_id)
                           values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.c('aa'), now() - interval '40 days', pg_temp.id('owner'), gen_random_uuid())$$);
select is(array[
  pg_temp.val_as('owner', $$select count(*) from public.get_customer_deliveries(pg_temp.id('plantA'), now() - interval '60 days')$$),
  pg_temp.val_as('owner', $$select count(*) from public.get_customer_deliveries(pg_temp.id('plantA'), now() - interval '1 hour')$$)],
  '{3,2}', 'p_since (default 7 days) never reaches more than 31 days back');
select is(pg_temp.run_as('ownerB', $$select * from public.get_customer_deliveries(pg_temp.id('plantA'))$$), 'NOT_AUTHORIZED',
  'another tenant''s owner: NOT_AUTHORIZED');

-- ══ customer_delivery alert ══════════════════════════════════════════════
select is((select count(*)::int from public.alert_events where kind = 'customer_delivery'), 3, 'one customer_delivery alert per delivery');
select is((select array_agg(a.recipients::text || ':' || coalesce((select d.entered_by from public.customer_deliveries d where d.id = a.subject_id) = pg_temp.id('owner'), false)
                          order by a.recipients::text) from public.alert_events a where a.kind = 'customer_delivery'),
  array['{}:false', '{}:false', '{quiet}:true'],
  'default level push: the manager''s deliveries are pending for the push; the owner''s own one is quiet (no OTHER owner to push to, 2026-11-09)');
select is((select array_agg(u) from public.alert_events a cross join lateral app.alert_recipient_users(a) u
            where a.kind = 'customer_delivery' and a.subject_id = (select id from public.customer_deliveries where client_id = 'd1000000-0000-0000-0000-000000000001')),
  array[pg_temp.id('owner')], 'pushed to the plant''s owners only');
select is((select app.alert_payload(a) - 'delivery_id' - 'delivered_at' - 'customer_id' from public.alert_events a
            where a.kind = 'customer_delivery' and a.subject_id = (select id from public.customer_deliveries where client_id = 'd1000000-0000-0000-0000-000000000001')),
  jsonb_build_object('customer_name', 'AA Test', 'customer_name_i18n', '{"es":"AA Prueba"}'::jsonb, 'voided', false, 'total_bins', 2.75,
    'lines', jsonb_build_array(
      jsonb_build_object('wash_group_id', pg_temp.c('gKT'), 'wash_group_name', 'Kitchen towels', 'wash_group_name_i18n', '{}'::jsonb, 'bins', 2.50, 'loads', 3.750),
      jsonb_build_object('wash_group_id', pg_temp.c('gAp'), 'wash_group_name', 'Aprons', 'wash_group_name_i18n', '{}'::jsonb, 'bins', 0.25, 'loads', null))),
  'payload: customer, delivered_at, lines (group + bins + loads); no names, no note');
select ok((select bool_and(app.alert_payload(a)::text !~* '(Ben|Manager A|Two bins wet|entered_by|staff)') from public.alert_events a where a.kind = 'customer_delivery'),
  'no payload carries a name, the PIN''s person or the note');
select is(array[
  pg_temp.val_as('owner',   $$select string_agg(kind || '=' || still_current || '/' || can_clear, ',') from public.get_my_alerts(pg_temp.id('plantA')) where kind = 'customer_delivery'$$),
  pg_temp.val_as('manager', $$select count(*) from public.get_my_alerts(pg_temp.id('plantA')) where kind = 'customer_delivery'$$)],
  array['customer_delivery=false/true,customer_delivery=false/true', '0'],
  'Alerts tab: owners see it (informational: not current, clearable), except the one they recorded themselves (2026-11-09); managers never');
select is(pg_temp.val_as('owner', $$select count(*) from public.clear_my_alerts(pg_temp.id('plantA'), array(select alert_id from public.get_my_alerts(pg_temp.id('plantA')) where kind = 'customer_delivery'))$$),
  '2', 'the owner clears them');

select * from finish();
rollback;
