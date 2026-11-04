-- M2 queue RPCs (PRD C1–C4; owner decision 2026-11-03): create / reorder / update / cancel /
-- set status, get_queue. Role matrix, validation, no-oracle pairs, idempotency, version conflicts.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(55);

-- Fixture washers: Washer 1 (fixture, washroom A). Add Washer 2 (inactive), a dryer, a finishing ironer,
-- and plant B washer + dryer.
insert into public.machines (id, org_id, plant_id, area_id, name, kind, active) values
  ('60000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 2', 'washer', false),
  ('60000000-0000-0000-0000-0000000000a4', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Dryer 1', 'dryer', true),
  ('60000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), 'Ironer M', 'ironer', true),
  ('60000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), 'Washer B', 'washer', true),
  ('60000000-0000-0000-0000-0000000000b2', pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), 'Dryer B', 'dryer', true);

-- Queue item by client id, and its current version.
create function pg_temp.cid(n int) returns uuid language sql immutable as $$
  select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;
$$;
create function pg_temp.q(n int) returns uuid language sql stable as $$
  select id from public.queue_items where client_id = pg_temp.cid(n);
$$;
create function pg_temp.v(n int) returns int language sql stable as $$
  select version from public.queue_items where client_id = pg_temp.cid(n);
$$;
grant execute on function pg_temp.cid(int), pg_temp.q(int), pg_temp.v(int) to authenticated, anon;
-- Board order of the area as client-id numbers.
create function pg_temp.board(p_area uuid) returns int[] language sql stable as $$
  select array_agg(right(q.client_id::text, 12)::int order by q.is_rush desc, q.position, q.id)
    from public.queue_items q where q.area_id = p_area and q.status in ('queued', 'in_progress') and q.client_id::text like 'c0000000%';
$$;

-- ── create_queue_item ─────────────────────────────────────────────────────
select is(pg_temp.writes($$select public.create_queue_item(pg_temp.id('wash'), 2, 'load', gen_random_uuid(), pg_temp.id('gMat'))$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'create_queue_item: owner/manager only (lead, viewer, display, other tenant: NOT_AUTHORIZED; anon: no EXECUTE)');
select is(pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 4, 'load', pg_temp.cid(1), pg_temp.id('gNapkin'), p_note => ' Club 6am ')$$), '1', 'normal item 1');
select is(pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 2, 'load', pg_temp.cid(2), pg_temp.id('gMat'))$$), '1', 'normal item 2');
select is(pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', pg_temp.cid(3), pg_temp.id('gTowel'), p_is_rush => true)$$), '1', 'rush item 3');
select is(pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 3, 'basket', pg_temp.cid(4), pg_temp.id('gTowel'), p_is_rush => true)$$), '1', 'rush item 4');
select is(pg_temp.board(pg_temp.id('wash')), array[4, 3, 1, 2], 'C1: rush lands on top of the rush items, normal work at the bottom');
select is((select array[note, created_by::text, status::text, version::text, loads_started::text] from public.queue_items where id = pg_temp.q(1)),
  array['Club 6am', pg_temp.id('owner')::text, 'queued', '1', '0'], 'note trimmed; created_by = caller; queued, version 1, no loads started');
select is((select array[loads_needed::text, loads_remaining::text] from public.queue_board where id = pg_temp.q(4)),
  array['2', '2'], 'queue_board: 3 baskets at 2/load → 2 loads needed (ceil of app.to_loads)');

-- Idempotency: the same client_id gives one row and the same id back.
select is(pg_temp.val_as('manager', $$select (public.create_queue_item(pg_temp.id('wash'), 9, 'load', pg_temp.cid(1), pg_temp.id('gMat'))).id$$), pg_temp.q(1)::text,
  'idempotent: a retry with the same client_id returns the existing row');
select is((select count(*)::int from public.queue_items where client_id = pg_temp.cid(1)), 1, 'idempotent: still one row');
select is(pg_temp.run_as('ownerB', $$select public.create_queue_item(pg_temp.id('washB'), 1, 'load', pg_temp.cid(1), pg_temp.id('groupB'))$$),
  'VALIDATION_FAILED', 'a client_id used in another tenant is rejected (never returns their row)');

-- Validation (as the manager on plant A).
select is(array[
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('fin'), 3, 'pack', gen_random_uuid(), pg_temp.id('gMat'), pg_temp.id('napkin'))$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 0, 'load', gen_random_uuid(), pg_temp.id('gMat'))$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1.234, 'load', gen_random_uuid(), pg_temp.id('gMat'))$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'), p_note => repeat('x', 141))$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'), p_note => E'a\tb')$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('fin'), 10, 'piece', gen_random_uuid(), pg_temp.id('gMat'))$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', null, pg_temp.id('gMat'))$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid())$$)],
  array['VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED'],
  'rejects: item outside the group, qty 0, 3 decimals, note > 140, control chars, piece without item, no client_id, no group');
select is(pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('fin'), 2, 'pack', gen_random_uuid(), p_item_type_id => pg_temp.id('mat'))$$),
  'COUNT_MODE_MISMATCH', 'unit pack needs a pack-counted item');
select is(pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('fin'), 2, 'pack', pg_temp.cid(5), p_item_type_id => pg_temp.id('napkin'))$$),
  '1', 'finishing item counted in packs (group taken from the item)');
select is((select wash_group_id from public.queue_items where id = pg_temp.q(5)), pg_temp.id('gNapkin'), 'group defaults to the item''s group');
select is(array[
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('fin'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'), p_is_rewash => true)$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'), p_assigned_machine_id => '60000000-0000-0000-0000-0000000000a4')$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'), p_assigned_machine_id => '60000000-0000-0000-0000-0000000000a2')$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('fin'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'), p_assigned_machine_id => pg_temp.id('machine'))$$)],
  array['VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED','VALIDATION_FAILED'],
  'rejects: rewash outside the washroom, a dryer, an inactive washer, a washer of another area');
select is(pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', pg_temp.cid(6), pg_temp.id('gMat'), p_assigned_machine_id => pg_temp.id('machine'), p_is_rewash => true)$$),
  '1', 'assigned to an active washer of the area, as a rewash');
select is((select array[assigned_machine_id::text, is_rewash::text] from public.queue_items where id = pg_temp.q(6)),
  array[pg_temp.id('machine')::text, 'true'], 'assignment and rewash stored');

-- No oracle: a foreign id and a missing id give the same answer.
select is(array[pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('washB'), 1, 'load', gen_random_uuid(), pg_temp.id('groupB'))$$),
                pg_temp.run_as('owner', $$select public.create_queue_item(gen_random_uuid(), 1, 'load', gen_random_uuid(), pg_temp.id('groupB'))$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED}', 'no oracle: another tenant''s area vs a missing area → NOT_AUTHORIZED');
select is(array[pg_temp.run_as('ownerB', $$select public.create_queue_item(pg_temp.id('washB'), 1, 'load', gen_random_uuid(), pg_temp.id('gTowel'))$$),
                pg_temp.run_as('ownerB', $$select public.create_queue_item(pg_temp.id('washB'), 1, 'load', gen_random_uuid(), pg_temp.id('gNapkin'))$$),
                pg_temp.run_as('ownerB', $$select public.create_queue_item(pg_temp.id('washB'), 1, 'load', gen_random_uuid(), gen_random_uuid())$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}', 'no oracle: plant A groups (baskets or not) vs a missing group → same error for owner B');
select is(array[pg_temp.run_as('ownerB', $$select public.create_queue_item(pg_temp.id('washB'), 1, 'pack', gen_random_uuid(), pg_temp.id('groupB'), pg_temp.id('napkin'))$$),
                pg_temp.run_as('ownerB', $$select public.create_queue_item(pg_temp.id('washB'), 1, 'pack', gen_random_uuid(), pg_temp.id('groupB'), pg_temp.id('mat'))$$),
                pg_temp.run_as('ownerB', $$select public.create_queue_item(pg_temp.id('washB'), 1, 'pack', gen_random_uuid(), pg_temp.id('groupB'), gen_random_uuid())$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}', 'no oracle: plant A pack item vs unit item vs missing item → same error (count mode not revealed)');
select is(array[pg_temp.run_as('ownerB', $$select public.create_queue_item(pg_temp.id('washB'), 1, 'load', gen_random_uuid(), pg_temp.id('groupB'), p_assigned_machine_id => pg_temp.id('machine'))$$),
                pg_temp.run_as('ownerB', $$select public.create_queue_item(pg_temp.id('washB'), 1, 'load', gen_random_uuid(), pg_temp.id('groupB'), p_assigned_machine_id => '60000000-0000-0000-0000-0000000000a4')$$),
                pg_temp.run_as('ownerB', $$select public.create_queue_item(pg_temp.id('washB'), 1, 'load', gen_random_uuid(), pg_temp.id('groupB'), p_assigned_machine_id => gen_random_uuid())$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}', 'no oracle: plant A washer vs dryer vs missing machine → same error');
select is(array[pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('groupA2'))$$),
                pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), gen_random_uuid())$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED}', 'no oracle, same org: plant A2 group vs missing group');
select ok((select count(*) = 1 from public.audit_log where entity = 'queue_items' and action = 'queue_items.insert' and entity_id = pg_temp.q(1)),
  'create is audited');

-- ── reorder_queue_item ────────────────────────────────────────────────────
select is(pg_temp.writes($$select public.reorder_queue_item(pg_temp.q(2), pg_temp.v(2), null)$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'reorder_queue_item: owner/manager only');
select is(pg_temp.board(pg_temp.id('wash')), array[4, 3, 2, 1, 6], 'item 2 moved to the top of the normal items');
select is(pg_temp.run_as('owner', $$select public.reorder_queue_item(pg_temp.q(2), pg_temp.v(2), pg_temp.q(1))$$), '1', 'move item 2 below item 1');
select is(pg_temp.board(pg_temp.id('wash')), array[4, 3, 1, 2, 6], 'midpoint between item 1 and item 6');
select is(pg_temp.run_as('owner', $$select public.reorder_queue_item(pg_temp.q(2), pg_temp.v(2) - 1, null)$$), 'QUEUE_VERSION_CONFLICT',
  'a stale version is a conflict');
select is(array[pg_temp.run_as('owner', $$select public.reorder_queue_item(pg_temp.q(2), pg_temp.v(2), pg_temp.q(3))$$),
                pg_temp.run_as('owner', $$select public.reorder_queue_item(pg_temp.q(2), pg_temp.v(2), pg_temp.q(5))$$),
                pg_temp.run_as('owner', $$select public.reorder_queue_item(pg_temp.q(2), pg_temp.v(2), pg_temp.q(2))$$),
                pg_temp.run_as('owner', $$select public.reorder_queue_item(pg_temp.q(2), pg_temp.v(2), 'e0000000-0000-0000-0000-0000000000b1')$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}',
  'after_id must be an open item of the same area and rush partition (not a rush item, another area, itself, or unknown)');
-- Gap < 1e-6 → the partition is renumbered, then the midpoint is taken.
update public.queue_items set position = 10 where id = pg_temp.q(1);
update public.queue_items set position = 10.0000001 where id = pg_temp.q(2);
select is(pg_temp.run_as('owner', $$select public.reorder_queue_item(pg_temp.q(6), pg_temp.v(6), pg_temp.q(1))$$), '1', 'move into a tiny gap');
select is(pg_temp.board(pg_temp.id('wash')), array[4, 3, 1, 6, 2], 'renumbered: item 6 sits between items 1 and 2');
select ok((select p2.position - p1.position = 1 and p6.position * 2 = p1.position + p2.position
             from public.queue_items p1, public.queue_items p2, public.queue_items p6
            where p1.id = pg_temp.q(1) and p2.id = pg_temp.q(2) and p6.id = pg_temp.q(6)),
  'positions renumbered to whole numbers, then the midpoint');

-- ── update_queue_item ─────────────────────────────────────────────────────
select is(pg_temp.writes($$select public.update_queue_item(pg_temp.q(2), pg_temp.v(2), 2, 'load', false, false, 'n', null)$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'update_queue_item: owner/manager only');
select is(pg_temp.run_as('owner', $$select public.update_queue_item(pg_temp.q(2), pg_temp.v(2), 5, 'load', true, false, null, null)$$), '1', 'RUSH on, qty 5, note cleared');
select is(pg_temp.board(pg_temp.id('wash')), array[2, 4, 3, 1, 6], 'C3: RUSH moves the item to the top');
select is((select array[qty::text, coalesce(note, 'null'), is_rush::text] from public.queue_items where id = pg_temp.q(2)),
  array['5.00', 'null', 'true'], 'fields replaced');
select is(pg_temp.run_as('owner', $$select public.update_queue_item(pg_temp.q(2), pg_temp.v(2) - 1, 5, 'load', true, false, null, null)$$),
  'QUEUE_VERSION_CONFLICT', 'stale version on update');
-- An item already on a washer that is now inactive can still be edited if the assignment is unchanged.
update public.queue_items set assigned_machine_id = '60000000-0000-0000-0000-0000000000a2' where id = pg_temp.q(1);
select is(array[pg_temp.run_as('owner', $$select public.update_queue_item(pg_temp.q(1), pg_temp.v(1), 4, 'load', false, false, 'kept', '60000000-0000-0000-0000-0000000000a2')$$),
                pg_temp.run_as('owner', $$select public.update_queue_item(pg_temp.q(6), pg_temp.v(6), 1, 'load', false, true, null, '60000000-0000-0000-0000-0000000000a2')$$),
                pg_temp.run_as('owner', $$select public.update_queue_item(pg_temp.q(1), pg_temp.v(1), 4, 'load', false, false, null, null)$$)],
  '{1,VALIDATION_FAILED,1}', 'unchanged inactive assignment is kept; a new one must be active; unassign (move a load off a broken washer)');
select is(pg_temp.run_as('owner', $$select public.update_queue_item(pg_temp.q(5), pg_temp.v(5), 2, 'pack', false, true, null, null)$$),
  'VALIDATION_FAILED', 'rewash is washroom-only on update too');
select is(array[pg_temp.run_as('ownerB', $$select public.update_queue_item(pg_temp.q(1), 1, 1, 'load', false, false, null, null)$$),
                pg_temp.run_as('ownerB', $$select public.update_queue_item(gen_random_uuid(), 1, 1, 'load', false, false, null, null)$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED}', 'no oracle: another tenant''s item vs a missing item');

-- ── set_queue_item_status ─────────────────────────────────────────────────
select is(pg_temp.run_as('lead', $$select public.set_queue_item_status(pg_temp.q(5), 'done', pg_temp.v(5))$$), '1',
  'C4: a lead completes a finishing item (queued → done passes through in_progress)');
select is((select array[status::text, (started_at is not null)::text, (completed_at is not null)::text] from public.queue_items where id = pg_temp.q(5)),
  array['done', 'true', 'true'], 'started_at and completed_at recorded');
select is(array[pg_temp.run_as('viewer', $$select public.set_queue_item_status(pg_temp.q(1), 'in_progress', pg_temp.v(1))$$),
                pg_temp.run_as('display', $$select public.set_queue_item_status(pg_temp.q(1), 'in_progress', pg_temp.v(1))$$),
                pg_temp.run_as('ownerB', $$select public.set_queue_item_status(pg_temp.q(1), 'in_progress', 1)$$),
                pg_temp.run_as('anon', $$select public.set_queue_item_status(pg_temp.q(1), 'in_progress', 1)$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'set_queue_item_status: viewer, display, other tenant denied');
select is(array[pg_temp.run_as('manager', $$select public.set_queue_item_status(pg_temp.q(1), 'cancelled', pg_temp.v(1))$$),
                pg_temp.run_as('manager', $$select public.set_queue_item_status(pg_temp.q(1), 'in_progress', pg_temp.v(1) + 5)$$)],
  '{VALIDATION_FAILED,QUEUE_VERSION_CONFLICT}', 'cancel goes through cancel_queue_item; versions are checked');
select is(pg_temp.run_as('owner', $$select public.update_queue_item(pg_temp.q(5), pg_temp.v(5), 2, 'pack', false, false, null, null)$$),
  'VALIDATION_FAILED', 'a done item cannot be edited');

-- ── cancel_queue_item ─────────────────────────────────────────────────────
select is(array[pg_temp.run_as('lead', $$select public.cancel_queue_item(pg_temp.q(6), pg_temp.v(6))$$),
                pg_temp.run_as('viewer', $$select public.cancel_queue_item(pg_temp.q(6), pg_temp.v(6))$$),
                pg_temp.run_as('ownerB', $$select public.cancel_queue_item(pg_temp.q(6), 1)$$),
                pg_temp.run_as('anon', $$select public.cancel_queue_item(pg_temp.q(6), 1)$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'cancel_queue_item: owner/manager only');
select is(pg_temp.run_as('manager', $$select public.cancel_queue_item(pg_temp.q(6), pg_temp.v(6) - 1)$$), 'QUEUE_VERSION_CONFLICT', 'cancel checks the version');
select is(pg_temp.run_as('manager', $$select public.cancel_queue_item(pg_temp.q(6), pg_temp.v(6))$$), '1', 'cancel');
select is(pg_temp.val_as('manager', $$select (public.cancel_queue_item(pg_temp.q(6), 1)).status$$), 'cancelled', 'cancel again: idempotent (returns the cancelled row)');
select is(pg_temp.run_as('owner', $$select public.cancel_queue_item(pg_temp.q(5), pg_temp.v(5))$$), 'INVALID_STATUS_TRANSITION', 'a done item cannot be cancelled');
select is((select count(*)::int from public.queue_items where id = pg_temp.q(6)), 1, 'cancelled, never deleted');

-- ── get_queue ─────────────────────────────────────────────────────────────
select is(pg_temp.reads($$select * from public.get_queue(pg_temp.id('wash'))$$),
  '{6,6,6,6,6,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'get_queue: plant roles and the washroom display; others denied');
select is(pg_temp.run_as('display', $$select * from public.get_queue(pg_temp.id('fin'))$$, true), 'NOT_AUTHORIZED',
  'a display cannot read another area''s queue');
select is(pg_temp.val_as('viewer', $$select array_agg(g.id)::text from public.get_queue(pg_temp.id('wash')) g$$),
  (select array_agg(b.id order by b.is_rush desc, b.position, b.id)::text from public.queue_board b where b.area_id = pg_temp.id('wash')),
  'get_queue returns the area''s open items in board order');

select * from finish();
rollback;
