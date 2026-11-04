-- Owner decisions 2026-11-02 (B + follow-up): queue_items.assigned_machine_id (null = next free washer).
-- Only a WASHER of the queue item's own area (hence its plant): composite FK
-- (assigned_machine_id, area_id, assigned_machine_kind = generated 'washer') → machines(id, area_id, kind).
-- No definer code, so every foreign/wrong/missing machine gives the same 23503 (no oracle).
-- queue_items.is_rewash: goods sent back by finishing.
-- M2: clients write queue_items only through the queue RPCs (100_queue_rpcs). The FK rules below run as
-- the service role (pg_temp.as_service), which is how the definer RPCs reach the table.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(45);

-- Machines: Washer 2 + Dryer 1 (washroom A), Ironer M (finishing A), plant B washer + dryer, plant A2 washer.
insert into public.machines (id, org_id, plant_id, area_id, name, kind) values
  ('60000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'),  pg_temp.id('wash'),   'Washer 2', 'washer'),
  ('60000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'),  pg_temp.id('fin'),    'Ironer M', 'ironer'),
  ('60000000-0000-0000-0000-0000000000a4', pg_temp.id('orgA'), pg_temp.id('plantA'),  pg_temp.id('wash'),   'Dryer 1',  'dryer'),
  ('60000000-0000-0000-0000-0000000000b2', pg_temp.id('orgB'), pg_temp.id('plantB'),  pg_temp.id('washB'),  'Dryer B',  'dryer'),
  ('60000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'),  pg_temp.id('washB'),  'Washer B', 'washer'),
  ('60000000-0000-0000-0000-0000000000c1', pg_temp.id('orgA'), pg_temp.id('plantA2'), pg_temp.id('washA2'), 'Washer A2', 'washer');

-- Queue items: q1 washroom (plant A), q2 finishing (plant A), qb washroom (plant B).
insert into public.queue_items (id, org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position, created_by, client_id) values
  ('e0000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), null, 4, 'load', 1, pg_temp.id('manager'), gen_random_uuid()),
  ('e0000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('gMat'), pg_temp.id('mat'), 10, 'piece', 1, pg_temp.id('manager'), gen_random_uuid()),
  ('e0000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), pg_temp.id('groupB'), null, 1, 'load', 1, pg_temp.id('ownerB'), gen_random_uuid());

-- ── Shape ─────────────────────────────────────────────────────────────────
select col_type_is('public', 'queue_items', 'assigned_machine_id', 'uuid', 'queue_items.assigned_machine_id is a uuid');
select col_is_null('public', 'queue_items', 'assigned_machine_id', 'assigned_machine_id is nullable (null = next free washer)');
select is((select assigned_machine_id from public.queue_items where id = 'e0000000-0000-0000-0000-0000000000a1'), null::uuid,
  'new queue items default to next free washer');
select has_index('public', 'queue_items', 'queue_items_assigned_washer_idx', array['assigned_machine_id', 'area_id', 'assigned_machine_kind'],
  'assigned washer FK is indexed');
select is((select array_agg(conname::text order by conname) from pg_constraint
            where conrelid = 'public.machines'::regclass and contype = 'u' and conname like 'machines_id_area%'),
  array['machines_id_area_kind_key'], 'machines has unique (id, area_id, kind) as the FK target (the old (id, area_id) key is gone)');
select is((select attgenerated::text from pg_attribute where attrelid = 'public.queue_items'::regclass and attname = 'assigned_machine_kind'),
  's', 'assigned_machine_kind is a stored generated column');
select is((select array_agg(policyname::text || ':' || cmd order by policyname) from pg_policies where schemaname = 'public' and tablename = 'queue_items'),
  array['queue_items_select:SELECT'], 'M2: queue_items keeps only its SELECT policy (writes via RPCs)');

-- ── Role matrix (M2: no direct C U for any role; lead, viewer R; display R own area) ──
select is(pg_temp.writes($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id, assigned_machine_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), 1, 'load', 9, (select auth.uid()), gen_random_uuid(), pg_temp.id('machine'))$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'M2: no direct insert with an assigned washer for any role');
select is(pg_temp.writes($$update public.queue_items set assigned_machine_id = '60000000-0000-0000-0000-0000000000a2' where id = 'e0000000-0000-0000-0000-0000000000a1'$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'M2: no direct assignment update for any role (update_queue_item)');
select is(pg_temp.as_service($$update public.queue_items set assigned_machine_id = '60000000-0000-0000-0000-0000000000a2' where id = 'e0000000-0000-0000-0000-0000000000a1'$$),
  '1', 'the service role assigns a washer');
select is((select array[assigned_machine_id::text, version::text, assigned_machine_kind::text] from public.queue_items where id = 'e0000000-0000-0000-0000-0000000000a1'),
  array['60000000-0000-0000-0000-0000000000a2', '2', 'washer'],
  'assignment bumps version (optimistic concurrency); kind generated as washer');
select ok((select count(*) >= 1 from public.audit_log where action = 'queue_items.update' and entity_id = 'e0000000-0000-0000-0000-0000000000a1'
             and after ->> 'assigned_machine_id' = '60000000-0000-0000-0000-0000000000a2'),
  'assignments are audited');
select is(pg_temp.run_as('ownerB', $$update public.queue_items set assigned_machine_id = '60000000-0000-0000-0000-0000000000b1' where plant_id = pg_temp.id('plantA')$$),
  '42501', 'owner of B cannot assign plant A queue items');
select is(pg_temp.reads($$select 1 from public.queue_items where plant_id = pg_temp.id('plantA') and assigned_machine_id is not null$$),
  '{1,1,1,1,1,0,0,0}', 'assigned items R: plant roles; display its own (washroom) area; no cross-tenant');

-- ── Washers only, and only of the item's own area (and so its plant) ─────
select is(pg_temp.as_service($$update public.queue_items set assigned_machine_id = '60000000-0000-0000-0000-0000000000a4' where id = 'e0000000-0000-0000-0000-0000000000a1'$$),
  '23503', 'a dryer of the same area is rejected (washers only)');
select is(pg_temp.as_service($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id, assigned_machine_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), 1, 'load', 9, pg_temp.id('manager'), gen_random_uuid(), '60000000-0000-0000-0000-0000000000a4')$$),
  '23503', 'insert: a dryer is rejected');
select is(array[pg_temp.as_service($$update public.queue_items set assigned_machine_kind = 'dryer' where id = 'e0000000-0000-0000-0000-0000000000a1'$$),
                pg_temp.as_service($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id, assigned_machine_id, assigned_machine_kind)
                  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), 1, 'load', 9, pg_temp.id('manager'), gen_random_uuid(), '60000000-0000-0000-0000-0000000000a4', 'dryer')$$)],
  '{428C9,428C9}', 'clients cannot write assigned_machine_kind (generated), so the FK always demands a washer');
select is(pg_temp.as_service($$update public.queue_items set assigned_machine_id = '60000000-0000-0000-0000-0000000000b1' where id = 'e0000000-0000-0000-0000-0000000000a1'$$),
  '23503', 'cross-tenant machine rejected');
select is(pg_temp.as_service($$update public.queue_items set assigned_machine_id = '60000000-0000-0000-0000-0000000000c1' where id = 'e0000000-0000-0000-0000-0000000000a1'$$),
  '23503', 'same org, other plant machine rejected');
select is(pg_temp.as_service($$update public.queue_items set assigned_machine_id = pg_temp.id('machine') where id = 'e0000000-0000-0000-0000-0000000000a2'$$),
  '23503', 'a finishing-area item cannot be assigned a washroom washer');
select is(pg_temp.as_service($$update public.queue_items set assigned_machine_id = '60000000-0000-0000-0000-0000000000a3' where id = 'e0000000-0000-0000-0000-0000000000a1'$$),
  '23503', 'a washroom item cannot be assigned a finishing-area machine');
select is(pg_temp.as_service($$update public.queue_items set assigned_machine_id = '60000000-0000-0000-0000-0000000000a3' where id = 'e0000000-0000-0000-0000-0000000000a2'$$),
  '23503', 'a finishing-area item cannot name its own area''s ironer (washers only)');
select is(pg_temp.as_service($$update public.queue_items set area_id = pg_temp.id('fin') where id = 'e0000000-0000-0000-0000-0000000000a1'$$),
  '23503', 'moving an assigned item to another area without clearing the machine is rejected');
select is(pg_temp.as_service($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id, assigned_machine_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('gNapkin'), 1, 'load', 9, pg_temp.id('manager'), gen_random_uuid(), pg_temp.id('machine'))$$),
  '23503', 'insert: finishing-area item with a washroom washer rejected');
select is(pg_temp.as_service($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id, assigned_machine_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), 1, 'load', 9, pg_temp.id('manager'), gen_random_uuid(), '60000000-0000-0000-0000-0000000000b1')$$),
  '23503', 'insert: cross-tenant washer rejected');
select is(pg_temp.as_service($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id, assigned_machine_id)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), 1, 'load', 9, pg_temp.id('manager'), gen_random_uuid(), '60000000-0000-0000-0000-0000000000b1')$$),
  '23503', 'a plant A item cannot name plant B''s washer');
-- The FK gives the same answer for a plant A washer, a plant A dryer and a missing UUID on a plant B item
-- (the RPC-level no-oracle pairs are in 100_queue_rpcs).
select is(array[pg_temp.as_service($$update public.queue_items set assigned_machine_id = pg_temp.id('machine') where id = 'e0000000-0000-0000-0000-0000000000b1'$$),
                pg_temp.as_service($$update public.queue_items set assigned_machine_id = '60000000-0000-0000-0000-0000000000a4' where id = 'e0000000-0000-0000-0000-0000000000b1'$$),
                pg_temp.as_service($$update public.queue_items set assigned_machine_id = gen_random_uuid() where id = 'e0000000-0000-0000-0000-0000000000b1'$$)],
  '{23503,23503,23503}', 'foreign washer vs foreign dryer vs missing machine → same 23503');
select is(pg_temp.as_service($$update public.queue_items set assigned_machine_id = '60000000-0000-0000-0000-0000000000b2' where id = 'e0000000-0000-0000-0000-0000000000b1'$$),
  '23503', 'owner B''s own dryer is rejected too');
select is(pg_temp.as_service($$update public.queue_items set assigned_machine_id = '60000000-0000-0000-0000-0000000000b1' where id = 'e0000000-0000-0000-0000-0000000000b1'$$),
  '1', 'owner B assigns their own washer');
select is(pg_temp.as_service($$update public.queue_items set assigned_machine_id = null where id = 'e0000000-0000-0000-0000-0000000000a2'$$),
  '1', 'clearing the assignment (back to next free washer) is allowed');

-- ── Security L2 decision: the assignment is history; a referenced machine's area/kind are fixed ──
select is(array[pg_temp.run_as('owner', $$update public.machines set kind = 'dryer' where id = '60000000-0000-0000-0000-0000000000a2'$$),
                pg_temp.run_as('owner', $$update public.machines set area_id = pg_temp.id('spare') where id = '60000000-0000-0000-0000-0000000000a2'$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED}', 'a machine referenced by a queue item cannot change kind or area (guard: deactivate + add new)');
select is(pg_temp.run_as('owner', $$update public.machines set active = false where id = '60000000-0000-0000-0000-0000000000a2'$$),
  '1', 'a referenced machine can still be deactivated');
update public.machines set active = true where id = '60000000-0000-0000-0000-0000000000a2';

-- ── queue_board carries the assignment ────────────────────────────────────
select is((select array[assigned_machine_id::text, assigned_machine_name] from public.queue_board where id = 'e0000000-0000-0000-0000-0000000000a1'),
  array['60000000-0000-0000-0000-0000000000a2', 'Washer 2'], 'queue_board shows the assigned washer');
select is(pg_temp.run_as('display', $$select 1 from public.queue_board where id = 'e0000000-0000-0000-0000-0000000000a1' and assigned_machine_name = 'Washer 2'$$, true),
  '1', 'the washroom display sees the assigned washer');
select is((select array[coalesce(assigned_machine_id::text, 'null'), coalesce(assigned_machine_name, 'null')] from public.queue_board where id = 'e0000000-0000-0000-0000-0000000000a2'),
  array['null', 'null'], 'unassigned item → null (next free washer)');

-- ── is_rewash: goods sent back by finishing (owner 2026-11-02) ─────────────
select col_not_null('public', 'queue_items', 'is_rewash', 'queue_items.is_rewash is not null');
select col_default_is('public', 'queue_items', 'is_rewash', 'false', 'is_rewash defaults to false');
select is((select is_rewash from public.queue_items where id = 'e0000000-0000-0000-0000-0000000000a1'), false, 'existing items are not rewash');
select is(pg_temp.writes($$insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id, is_rewash)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), pg_temp.id('gNapkin'), 1, 'load', 20, (select auth.uid()), gen_random_uuid(), true)$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'M2: no direct rewash insert for any role');
select is(pg_temp.writes($$update public.queue_items set is_rewash = true where id = 'e0000000-0000-0000-0000-0000000000a1'$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'M2: no direct is_rewash update for any role');
update public.queue_items set is_rewash = true where id = 'e0000000-0000-0000-0000-0000000000a1';
select is((select count(*)::int from public.queue_board where plant_id = pg_temp.id('plantA') and is_rewash), 1,
  'queue_board exposes is_rewash');
select is(pg_temp.run_as('display', $$select 1 from public.queue_board where is_rewash$$, true), '1',
  'the washroom display sees which loads are rewash');
select is((select array_agg(attname::text order by attnum) from pg_attribute where attrelid = 'public.queue_board'::regclass and attnum > 25),
  array['is_rewash', 'loads_started', 'loads_needed', 'loads_remaining'], 'queue_board: is_rewash, then the M2 progress columns, appended');

-- L2: completing or cancelling an item leaves its washer assignment as history.
select is(array[pg_temp.as_service($$update public.queue_items set status = 'in_progress' where id = 'e0000000-0000-0000-0000-0000000000a1'$$),
                pg_temp.as_service($$update public.queue_items set status = 'done' where id = 'e0000000-0000-0000-0000-0000000000a1'$$)],
  '{1,1}', 'assigned item runs to done');
select is((select assigned_machine_id from public.queue_items where id = 'e0000000-0000-0000-0000-0000000000a1'),
  '60000000-0000-0000-0000-0000000000a2'::uuid, 'a completed item keeps its assigned washer (history)');

select * from finish();
rollback;
