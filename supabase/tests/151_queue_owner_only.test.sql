-- Queue editing is owner-only with two manager exceptions (owner 2026-11-04, rounds 2 and 3):
--   1. update_queue_item: a manager may move a load OFF a washer that is down (marked down, or
--      deactivated) to another active washer that is not down, or to unassigned; nothing else changes.
--   2. create_queue_item: a manager may add a REWASH item: not rush, not assigned, in load/basket/bin,
--      at the bottom of the normal items.
-- Everything else by a manager: NOT_AUTHORIZED (no oracle). Leads and viewers: unchanged (no edits).
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(27);

-- Washer 1 (fixture), Washer 2, Washer 3 (all active) in washroom A; Washer B in plant B.
insert into public.machines (id, org_id, plant_id, area_id, name, kind, active) values
  ('60000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 2', 'washer', true),
  ('60000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 3', 'washer', true),
  ('60000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), pg_temp.id('washB'), 'Washer B', 'washer', true);
update public.wash_groups set loads_per_bin = 2, allow_bin_estimates = true where id = pg_temp.id('gNapkin');

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
-- update_queue_item for item n with every field unchanged except the assignment (p_to), as SQL text.
create function pg_temp.move_sql(n int, p_to text, p_version text default null) returns text language sql immutable as $$
  select format($f$select public.update_queue_item(q.id, %s, q.qty, q.unit, q.is_rush, q.is_rewash, q.note, %s)
                     from public.queue_items q where q.client_id = pg_temp.cid(%s)$f$,
                coalesce(p_version, 'q.version'), p_to, n);
$$;
create function pg_temp.board(p_area uuid) returns int[] language sql stable as $$
  select array_agg(right(q.client_id::text, 12)::int order by q.is_rush desc, q.position, q.id)
    from public.queue_items q where q.area_id = p_area and q.status in ('queued', 'in_progress') and q.client_id::text like 'c0000000%';
$$;

-- Owner's queue: 1 normal (Washer 2), 2 rush, 3 normal (Washer 1, with a note).
select is(array[
  pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 2, 'load', pg_temp.cid(1), pg_temp.id('gMat'), p_assigned_machine_id => '60000000-0000-0000-0000-0000000000a2')$$),
  pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', pg_temp.cid(2), pg_temp.id('gNapkin'), p_is_rush => true)$$),
  pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 3, 'load', pg_temp.cid(3), pg_temp.id('gMat'), p_note => 'Club', p_assigned_machine_id => pg_temp.id('machine'))$$)],
  '{1,1,1}', 'the owner creates normal, rush and assigned work');

-- ══ Exception 2: managers add rewash items only ══════════════════════════
select is(array[
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'))$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'), p_is_rush => true, p_is_rewash => true)$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'), p_is_rewash => true, p_assigned_machine_id => pg_temp.id('machine'))$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 10, 'piece', gen_random_uuid(), pg_temp.id('gNapkin'), pg_temp.id('napkin'), p_is_rewash => true)$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'pack', gen_random_uuid(), pg_temp.id('gNapkin'), pg_temp.id('napkin'), p_is_rewash => true)$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, null, gen_random_uuid(), pg_temp.id('gMat'), p_is_rewash => true)$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'), p_is_rush => null, p_is_rewash => true)$$)],
  array['NOT_AUTHORIZED','NOT_AUTHORIZED','NOT_AUTHORIZED','NOT_AUTHORIZED','NOT_AUTHORIZED','NOT_AUTHORIZED','NOT_AUTHORIZED'],
  'manager create: normal work, rush rewash, assigned rewash, piece/pack, no unit, null rush → NOT_AUTHORIZED');
select is(array[
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1.5, 'load', pg_temp.cid(4), pg_temp.id('gMat'), p_is_rewash => true, p_note => 'stains')$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 0.75, 'basket', pg_temp.cid(5), pg_temp.id('gTowel'), p_is_rewash => true)$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1.5, 'bin', pg_temp.cid(6), pg_temp.id('gNapkin'), p_is_rewash => true)$$)],
  '{1,1,1}', 'manager create: rewash in loads, baskets (¾ basket) or bins (1½ bins)');
select is(pg_temp.board(pg_temp.id('wash')), array[2, 1, 3, 4, 5, 6], 'rewash items land at the bottom of the normal items');
select is((select array_agg(row(is_rewash, is_rush, assigned_machine_id is null, created_by = pg_temp.id('manager'))::text order by client_id)
             from public.queue_items where client_id in (pg_temp.cid(4), pg_temp.cid(5), pg_temp.cid(6))),
  array['(t,f,t,t)', '(t,f,t,t)', '(t,f,t,t)'], 'rewash, not rush, unassigned, created by the manager');
select is((select array_agg(loads_needed order by unit) from public.queue_board where id in (pg_temp.q(5), pg_temp.q(6))),
  array[1, 3], 'loads needed: ¾ basket × 0.5 → 1; 1½ bins × 2 → 3 (via app.to_loads)');
select is(pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('fin'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'), p_is_rewash => true)$$),
  'VALIDATION_FAILED', 'rewash only in a washroom area (same rule as for the owner)');
select is(array[
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('washB'), 1, 'load', gen_random_uuid(), pg_temp.id('groupB'), p_is_rewash => true)$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(gen_random_uuid(), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'), p_is_rewash => true)$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('washA2'), 1, 'load', gen_random_uuid(), pg_temp.id('groupA2'), p_is_rewash => true)$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}', 'no oracle: another tenant''s, a missing, and another plant''s area look the same');
select is(pg_temp.writes($$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gMat'), p_is_rewash => true)$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'rewash create matrix: owner and manager; lead, viewer, display, other tenant NOT_AUTHORIZED; anon no EXECUTE');
select is(pg_temp.val_as('manager', $$select (public.create_queue_item(pg_temp.id('wash'), 9, 'load', pg_temp.cid(4), pg_temp.id('gMat'), p_is_rewash => true)).id$$),
  pg_temp.q(4)::text, 'manager rewash create is idempotent on client_id');

-- ══ Owner-only: reorder, cancel, other edits ═════════════════════════════
select is(array[
  pg_temp.run_as('manager', $$select public.reorder_queue_item(pg_temp.q(3), pg_temp.v(3), null)$$),
  pg_temp.run_as('manager', $$select public.reorder_queue_item(pg_temp.q(4), pg_temp.v(4), null)$$),
  pg_temp.run_as('manager', $$select public.cancel_queue_item(pg_temp.q(4), pg_temp.v(4))$$),
  pg_temp.run_as('manager', $$select public.cancel_queue_item(pg_temp.q(3), 999)$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}',
  'manager: no reorder, no cancel (not even their own rewash items; a stale version is NOT_AUTHORIZED too)');
select is(array[
  pg_temp.run_as('manager', $$select public.update_queue_item(q.id, q.version, 5, q.unit, q.is_rush, q.is_rewash, q.note, q.assigned_machine_id) from public.queue_items q where q.client_id = pg_temp.cid(3)$$),
  pg_temp.run_as('manager', $$select public.update_queue_item(q.id, q.version, q.qty, q.unit, true, q.is_rewash, q.note, q.assigned_machine_id) from public.queue_items q where q.client_id = pg_temp.cid(4)$$),
  pg_temp.run_as('manager', pg_temp.move_sql(3, 'null')),
  pg_temp.run_as('manager', pg_temp.move_sql(1, '''60000000-0000-0000-0000-0000000000a3''')),
  pg_temp.run_as('manager', pg_temp.move_sql(4, '''60000000-0000-0000-0000-0000000000a3'''))],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}',
  'manager update: qty, rush (even on their rewash item), and moving loads off washers that are UP (or unassigned work) → NOT_AUTHORIZED');
select is(pg_temp.run_as('owner', $$select public.reorder_queue_item(pg_temp.q(4), pg_temp.v(4), null)$$), '1', 'the owner reorders');
select is(pg_temp.run_as('owner', $$select public.update_queue_item(q.id, q.version, 4, q.unit, q.is_rush, q.is_rewash, 'Club 6am', q.assigned_machine_id) from public.queue_items q where q.client_id = pg_temp.cid(3)$$),
  '1', 'the owner edits any field');

-- ══ Exception 1: managers move loads off a DOWN washer ═══════════════════
select is(pg_temp.run_as('owner', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), 'Leaking')$$), '1', 'Washer 1 is down');
select is(array[
  pg_temp.run_as('manager', $$select public.update_queue_item(q.id, q.version, 5, q.unit, q.is_rush, q.is_rewash, q.note, null) from public.queue_items q where q.client_id = pg_temp.cid(3)$$),
  pg_temp.run_as('manager', $$select public.update_queue_item(q.id, q.version, q.qty, q.unit, q.is_rush, q.is_rewash, 'moved', null) from public.queue_items q where q.client_id = pg_temp.cid(3)$$),
  pg_temp.run_as('manager', $$select public.update_queue_item(q.id, q.version, q.qty, q.unit, true, q.is_rewash, q.note, null) from public.queue_items q where q.client_id = pg_temp.cid(3)$$),
  pg_temp.run_as('manager', $$select public.update_queue_item(q.id, q.version, q.qty, q.unit, q.is_rush, true, q.note, null) from public.queue_items q where q.client_id = pg_temp.cid(3)$$),
  pg_temp.run_as('manager', $$select public.update_queue_item(q.id, q.version, q.qty, 'basket', q.is_rush, q.is_rewash, q.note, null) from public.queue_items q where q.client_id = pg_temp.cid(3)$$),
  pg_temp.run_as('manager', pg_temp.move_sql(3, 'q.assigned_machine_id'))],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}',
  'moving off a down washer: any other change (qty, note, rush, rewash, unit) or no move at all → NOT_AUTHORIZED');
select is(pg_temp.run_as('manager', pg_temp.move_sql(3, 'null', 'q.version - 1')), 'QUEUE_VERSION_CONFLICT',
  'an allowed move still checks the version');
select is(pg_temp.run_as('manager', pg_temp.move_sql(3, '''60000000-0000-0000-0000-0000000000b1''')), 'VALIDATION_FAILED',
  'the target must be an active washer of the same area (not another tenant''s)');
select is(pg_temp.run_as('manager', pg_temp.move_sql(3, '''60000000-0000-0000-0000-0000000000a3''')), '1',
  'manager moves the load from down Washer 1 to Washer 3');
select is((select array[assigned_machine_id::text, qty::text, note, is_rush::text, updated_by::text] from public.queue_items where client_id = pg_temp.cid(3)),
  array['60000000-0000-0000-0000-0000000000a3', '4.00', 'Club 6am', 'false', pg_temp.id('manager')::text], 'only the washer changed');
select is(pg_temp.run_as('owner', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a2', 'down', gen_random_uuid(), 'No water')$$), '1', 'Washer 2 is down too');
select is(pg_temp.run_as('manager', pg_temp.move_sql(1, 'pg_temp.id(''machine'')')), 'MACHINE_DOWN',
  'moving onto another down washer → MACHINE_DOWN');
select is(pg_temp.run_as('manager', pg_temp.move_sql(1, 'null')), '1', 'manager moves the load from down Washer 2 to unassigned (next free washer)');
select is((select assigned_machine_id from public.queue_items where client_id = pg_temp.cid(1)), null, 'unassigned');

-- A washer that was deactivated counts as down for this rule.
select is(pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', pg_temp.cid(7), pg_temp.id('gMat'), p_assigned_machine_id => '60000000-0000-0000-0000-0000000000a3')$$),
  '1', 'owner assigns a load to Washer 3');
update public.machines set active = false where id = '60000000-0000-0000-0000-0000000000a3';
select is(pg_temp.run_as('manager', pg_temp.move_sql(7, 'null')), '1', 'Washer 3 deactivated: the manager may move its load off');

-- No oracle on another tenant's item; leads and viewers unchanged.
select set_config('test.q3', pg_temp.q(3)::text, true);
select is(array[
  pg_temp.run_as('ownerB', $$select public.update_queue_item(current_setting('test.q3')::uuid, 1, 1, 'load', false, false, null, null)$$),
  pg_temp.run_as('ownerB', $$select public.update_queue_item(gen_random_uuid(), 1, 1, 'load', false, false, null, null)$$),
  pg_temp.run_as('lead', pg_temp.move_sql(3, 'null')),
  pg_temp.run_as('viewer', pg_temp.move_sql(3, 'null'))],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}',
  'other tenant (foreign or missing item), lead, viewer: NOT_AUTHORIZED');

select * from finish();
rollback;
