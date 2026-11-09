-- Off-queue start reasons (owner decision 2026-11-09, option a; 20261109153206): a washer start that is not
-- the queue's next item for that washer needs a one-tap reason (not_ready | wrong_washer | urgent | other),
-- else OFF_QUEUE_REASON_REQUIRED; the skipped item is untouched; the owner reads today's count by reason
-- (get_off_queue_starts). No push, no alert, no person identity.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(49);

-- Washer 2 (factor 1.19) and Washer 3 in washroom A; a washer in plant A2. Napkins wash on a 30-min formula.
insert into public.machines (id, org_id, plant_id, area_id, name, kind, active, load_factor) values
  ('60000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 2', 'washer', true, 1.19),
  ('60000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 3', 'washer', true, 1.00),
  ('60000000-0000-0000-0000-0000000000c1', pg_temp.id('orgA'), pg_temp.id('plantA2'), pg_temp.id('washA2'), 'Washer A2', 'washer', true, 1.00);
update public.wash_formulas set cycle_minutes = 30 where id = pg_temp.id('formula');
update public.wash_groups set wash_formula_id = pg_temp.id('formula') where id = pg_temp.id('gNapkin');

create function pg_temp.cid(n int) returns uuid language sql immutable as $$
  select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;
$$;
-- Lookups run as the test owner (RLS limits manager/lead reads to the current shift, a wall-clock matter).
create function pg_temp.q(n int) returns uuid language sql stable security definer as $$
  select id from public.queue_items where client_id = pg_temp.cid(n);
$$;
create function pg_temp.cyc(n int) returns uuid language sql stable security definer as $$
  select id from public.washer_cycles where client_id = pg_temp.cid(n);
$$;
grant execute on function pg_temp.cid(int), pg_temp.q(int), pg_temp.cyc(int) to authenticated, anon;
create function pg_temp.qstate(n int) returns text[] language sql stable as $$
  select array[status::text, loads_started::text] from public.queue_items where id = pg_temp.q(n);
$$;
create function pg_temp.oq(n int) returns text[] language sql stable as $$
  select array[coalesce(off_queue::text, 'none'), coalesce(off_queue_reason, 'none')] from public.washer_cycles where client_id = pg_temp.cid(n);
$$;
-- Like run_as, but returns "CODE|detail" on error.
create function pg_temp.err_as(p_user text, p_sql text) returns text language plpgsql as $$
declare
  d text;
begin
  perform pg_temp.login(pg_temp.id(p_user));
  execute p_sql;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  return 'ok';
exception when others then
  get stacked diagnostics d = pg_exception_detail;
  perform set_config('request.jwt.claims', '', true);
  return sqlerrm || '|' || coalesce(d, '');
end;
$$;
-- get_off_queue_starts as the owner: "reason:starts:loads:last_at set?" in the function's row order.
create function pg_temp.counts(p_plant uuid, p_date date default null) returns text language sql as $$
  select pg_temp.val_as('owner', format($q$select array_agg(x.reason || ':' || x.starts || ':' || x.loads || ':' || (x.last_at is not null) order by x.o)::text
    from (select r.*, row_number() over () as o from public.get_off_queue_starts(%L::uuid, %L::date) r) x$q$, p_plant, p_date));
$$;

-- ══ Schema ═══════════════════════════════════════════════════════════════
select is(array[has_column_privilege('authenticated', 'public.washer_cycles', 'off_queue', 'select'),
                has_column_privilege('authenticated', 'public.washer_cycles', 'off_queue_reason', 'select'),
                has_column_privilege('authenticated', 'public.washer_cycles', 'off_queue_reason', 'update'),
                has_column_privilege('authenticated', 'public.washer_cycles', 'off_queue_reason', 'insert')],
  '{t,t,f,f}', 'clients may read off_queue / off_queue_reason (no identity in them) but never write them');
select is((select count(*)::int from pg_catalog.pg_proc where proname = 'start_washer_load' and pronamespace = 'public'::regnamespace),
  1, 'start_washer_load keeps exactly one signature');
select ok(has_function_privilege('authenticated', 'public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean, text)', 'execute')
          and has_function_privilege('service_role', 'public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean, text)', 'execute')
          and not has_function_privilege('anon', 'public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean, text)', 'execute')
          and not has_function_privilege('public', 'public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean, text)', 'execute'),
  'start_washer_load EXECUTE: authenticated and service_role only');
select ok(has_function_privilege('authenticated', 'public.get_off_queue_starts(uuid, date)', 'execute')
          and has_function_privilege('service_role', 'public.get_off_queue_starts(uuid, date)', 'execute')
          and not has_function_privilege('anon', 'public.get_off_queue_starts(uuid, date)', 'execute')
          and not has_function_privilege('public', 'public.get_off_queue_starts(uuid, date)', 'execute'),
  'get_off_queue_starts EXECUTE: authenticated and service_role only');
select ok(obj_description('public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean, text)'::regprocedure, 'pg_proc') like '%OFF_QUEUE_REASON_REQUIRED%'
          and obj_description('public.get_off_queue_starts(uuid, date)'::regprocedure, 'pg_proc') like '%OWNER only%',
  'both functions are documented');
select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'public.get_off_queue_starts(uuid, date)'::regprocedure),
  'get_off_queue_starts is security definer with an empty search_path');

-- ══ Queue: N napkins ×3 assigned to Washer 1; M mats ×2 and T towels ×2 unassigned (in that order) ══
select is(array[
  pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 3, 'load', pg_temp.cid(1), pg_temp.id('gNapkin'), p_assigned_machine_id => pg_temp.id('machine'))$$),
  pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 2, 'load', pg_temp.cid(2), pg_temp.id('gMat'))$$),
  pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 2, 'load', pg_temp.cid(3), pg_temp.id('gTowel'))$$)],
  '{1,1,1}', 'queue set up');

-- ══ Reason required ══════════════════════════════════════════════════════
-- Washer 2's next is M (mats). Towels hand-picked without a reason:
select is(pg_temp.writes($$select public.start_washer_load('60000000-0000-0000-0000-0000000000a2', gen_random_uuid(), null, pg_temp.id('gTowel'))$$),
  '{OFF_QUEUE_REASON_REQUIRED,OFF_QUEUE_REASON_REQUIRED,OFF_QUEUE_REASON_REQUIRED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'hand-picked group without a reason: OFF_QUEUE_REASON_REQUIRED for owner/manager/lead; viewer, display and other tenant NOT_AUTHORIZED first (no oracle); anon no EXECUTE');
select is(pg_temp.err_as('lead', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000a2', gen_random_uuid(), null, pg_temp.id('gTowel'))$$),
  'OFF_QUEUE_REASON_REQUIRED|p_off_queue_reason: required (not the queue''s next for this washer); expected_wash_group_id=' || pg_temp.id('gMat'),
  'the detail names the wash group the queue had next for this washer');
select is(array[(select count(*)::text from public.washer_cycles where plant_id = pg_temp.id('plantA')),
                array_to_string(pg_temp.qstate(2), '/'), array_to_string(pg_temp.qstate(3), '/')],
  array['0', 'queued/0', 'queued/0'], 'a refused start writes no cycle and takes nothing off the queue');
select is(pg_temp.run_as('lead', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000a2', gen_random_uuid(), null, pg_temp.id('gTowel'), p_off_queue_reason => 'lazy')$$),
  'VALIDATION_FAILED', 'an unknown reason code: VALIDATION_FAILED');
select is(pg_temp.run_as('ownerB', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000a2', gen_random_uuid(), null, pg_temp.id('gTowel'), p_off_queue_reason => 'lazy')$$),
  'NOT_AUTHORIZED', 'another tenant gets NOT_AUTHORIZED before any argument check');

-- With a reason: three towel loads on Washer 2 (the 2-load T item, then an off-queue towels load).
select is(pg_temp.writes($$select public.start_washer_load('60000000-0000-0000-0000-0000000000a2', gen_random_uuid(), null, pg_temp.id('gTowel'), p_confirm_running => true, p_off_queue_reason => 'not_ready')$$),
  '{1,1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'with a reason: owner/manager/lead start it; the others are still refused');
select is((select array_agg(coalesce(queue_item_id::text, 'none') || ':' || off_queue || ':' || off_queue_reason || ':' || load_factor_used order by 1)
             from public.washer_cycles where machine_id = '60000000-0000-0000-0000-0000000000a2'),
  array[pg_temp.q(3) || ':true:not_ready:1.19', pg_temp.q(3) || ':true:not_ready:1.19', 'none:true:not_ready:1.19'],
  'stored: off_queue true + the reason on each (two from the towels item, one off-queue load; sorted)');
select is(array[array_to_string(pg_temp.qstate(2), '/'), array_to_string(pg_temp.qstate(3), '/')],
  array['queued/0', 'done/2'], 'the skipped mats item is untouched (still queued, 0 loads); the picked towels item advanced');

-- ══ On-queue starts: any reason is ignored ═══════════════════════════════
select is(pg_temp.run_as('lead', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000a3', pg_temp.cid(10), p_off_queue_reason => 'urgent')$$),
  '1', 'Washer 3 takes its next item (mats) with a reason sent anyway');
select is(pg_temp.oq(10), '{false,none}', 'on-queue: off_queue false, the reason is not stored');
select is(pg_temp.run_as('lead', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000a3', pg_temp.cid(11), null, pg_temp.id('gMat'), p_confirm_running => true)$$),
  '1', 'choosing the group the queue has next is on-queue (no reason needed)');
select is(array[pg_temp.oq(11)::text, array_to_string(pg_temp.qstate(2), '/')], array['{false,none}', 'done/2'],
  'stored as on-queue; the mats item is done');

-- ══ Nothing queued for the washer (N is assigned to Washer 1 only) ═══════
select is(pg_temp.run_as('lead', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000a3', pg_temp.cid(12), null, pg_temp.id('gMat'), p_confirm_running => true)$$),
  '1', 'nothing queued for this washer: a load of a chosen group needs no reason (meta/owner 2026-11-09)');
select is(pg_temp.oq(12), '{false,none}', 'stored: off_queue false, no reason');
select is(pg_temp.run_as('manager', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000a3', pg_temp.cid(13), null, pg_temp.id('gMat'), p_confirm_running => true, p_off_queue_reason => 'other')$$),
  '1', 'a reason sent anyway with nothing queued …');
select is(pg_temp.oq(13), '{false,none}', '… is ignored (not off-queue)');

-- ══ Washer 1: its assigned item; the reason check comes before WASHER_RUNNING ══
select is(pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(20))$$), '1',
  'Washer 1 starts its assigned napkins item (now running, 30-min formula)');
select is(pg_temp.oq(20), '{false,none}', 'on-queue');
select is(array[
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(21), null, pg_temp.id('gTowel'))$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(21), null, pg_temp.id('gTowel'), p_off_queue_reason => 'wrong_washer')$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(21), null, pg_temp.id('gTowel'), p_confirm_running => true, p_off_queue_reason => 'wrong_washer')$$)],
  '{OFF_QUEUE_REASON_REQUIRED,WASHER_RUNNING,1}',
  'off-queue on a running washer: first the reason, then the running confirmation; a retry with both answers is saved');
select is(array[pg_temp.oq(21)::text, array_to_string(pg_temp.qstate(1), '/')], array['{true,wrong_washer}', 'in_progress/1'],
  'stored with its reason; the napkins item it skipped is untouched');

-- Idempotency first: a retry of the saved tap returns it without any reason or confirmation.
select is(array[
  pg_temp.val_as('lead', $$select (public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(21), null, pg_temp.id('gTowel'))).duplicate$$),
  pg_temp.val_as('lead', $$select (public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(21), null, pg_temp.id('gTowel'), p_off_queue_reason => 'lazy')).duplicate$$)],
  '{true,true}', 'idempotent retry: duplicate, before the reason check and the reason validation');
select is((select count(*)::int from public.washer_cycles where client_id = pg_temp.cid(21)), 1, 'still one row');

-- An explicit queue item: same group as the next one is on-queue, another group is off-queue.
select is(pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', pg_temp.cid(4), pg_temp.id('gNapkin'))$$), '1',
  'another napkins item, unassigned');
select is(pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(22), pg_temp.q(4), p_confirm_running => true)$$), '1',
  'Washer 1 starts the other napkins item explicitly');
select is(pg_temp.oq(22), '{false,none}', 'same group as the queue''s next: on-queue');
select is(pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', pg_temp.cid(5), pg_temp.id('gMat'))$$), '1',
  'a mats item, unassigned');
select is(pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), pg_temp.q(5), p_confirm_running => true)$$),
  'OFF_QUEUE_REASON_REQUIRED', 'an explicit item of another group than the next: reason required');

-- ══ Column rules ═════════════════════════════════════════════════════════
select is(array[
  pg_temp.as_service($$insert into public.washer_cycles (org_id, plant_id, area_id, machine_id, wash_group_id, started_at, load_count, source, client_id, off_queue, off_queue_reason)
                      values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), '60000000-0000-0000-0000-0000000000a3', pg_temp.id('gMat'), now() - interval '2 hours', 1, 'manual', gen_random_uuid(), true, 'lazy')$$),
  pg_temp.as_service($$insert into public.washer_cycles (org_id, plant_id, area_id, machine_id, wash_group_id, started_at, load_count, source, client_id, off_queue, off_queue_reason)
                      values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), '60000000-0000-0000-0000-0000000000a3', pg_temp.id('gMat'), now() - interval '2 hours', 1, 'manual', gen_random_uuid(), true, null)$$),
  pg_temp.as_service($$insert into public.washer_cycles (org_id, plant_id, area_id, machine_id, wash_group_id, started_at, load_count, source, client_id, off_queue, off_queue_reason)
                      values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), '60000000-0000-0000-0000-0000000000a3', pg_temp.id('gMat'), now() - interval '2 hours', 1, 'manual', gen_random_uuid(), false, 'urgent')$$),
  pg_temp.as_service($$insert into public.washer_cycles (org_id, plant_id, area_id, machine_id, wash_group_id, started_at, load_count, source, client_id)
                      values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), '60000000-0000-0000-0000-0000000000a3', pg_temp.id('gMat'), now() - interval '2 hours', 1, 'manual', pg_temp.cid(30))$$)],
  '{23514,23514,23514,1}',
  'CHECKs: an unknown reason, off_queue without a reason and a reason without off_queue are rejected; an unjudged row (both null, e.g. an import) is allowed');
select is(array[
  pg_temp.as_service($$update public.washer_cycles set off_queue_reason = 'urgent' where client_id = pg_temp.cid(21)$$),
  pg_temp.as_service($$update public.washer_cycles set off_queue = true, off_queue_reason = 'other' where client_id = pg_temp.cid(30)$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED}', 'off_queue / off_queue_reason are frozen after insert, even for the service role');

-- ══ Another plant of the same org: its queue has a second group next ═════
insert into public.wash_groups (id, org_id, plant_id, name) values
  ('71000000-0000-0000-0000-0000000000c2', pg_temp.id('orgA'), pg_temp.id('plantA2'), 'Group A2b');
select is(pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('washA2'), 1, 'load', pg_temp.cid(41), '71000000-0000-0000-0000-0000000000c2')$$), '1',
  'plant A2: Group A2b queued');
select is(pg_temp.run_as('owner', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000c1', pg_temp.cid(40), null, pg_temp.id('groupA2'), p_off_queue_reason => 'urgent')$$),
  '1', 'plant A2: an urgent off-queue load');

-- ══ A voided start does not count ═══════════════════════════════════════
select is(pg_temp.val_as('owner', $$select (public.undo_washer_load((select id from public.washer_cycles where machine_id = '60000000-0000-0000-0000-0000000000a2' and queue_item_id is null), 'test')).duplicate$$),
  'false', 'the owner undoes Washer 2''s off-queue towels load (voided)');

-- ══ get_off_queue_starts ═════════════════════════════════════════════════
select is(pg_temp.reads($$select * from public.get_off_queue_starts(pg_temp.id('plantA'))$$),
  '{4,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'get_off_queue_starts: OWNER only (manager, lead, viewer, display, other tenant NOT_AUTHORIZED; anon no EXECUTE)');
select is(array[pg_temp.run_as('owner', $$select * from public.get_off_queue_starts(gen_random_uuid())$$, true),
                pg_temp.run_as('ownerB', $$select * from public.get_off_queue_starts(pg_temp.id('plantA'))$$, true),
                pg_temp.run_as('ownerB', $$select * from public.get_off_queue_starts(null)$$, true)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}', 'a missing plant, another tenant''s plant and null: the same NOT_AUTHORIZED (no oracle)');
select is((select pg_temp.counts(pg_temp.id('plantA'))),
  '{not_ready:2:2.38:true,wrong_washer:1:1.00:true,urgent:0:0:false,other:0:0:false}',
  'today, plant A: count by reason (all four, fixed order), standard loads (Washer 2 is 1.19), last_at; the voided start, on-queue and nothing-queued starts, unjudged rows and plant A2 are left out');
select is(pg_temp.val_as('owner', $$select by_wash_group from public.get_off_queue_starts(pg_temp.id('plantA')) where reason = 'not_ready'$$)::jsonb,
  jsonb_build_array(jsonb_build_object('wash_group_id', pg_temp.id('gTowel'), 'wash_group_name', 'Towels',
                                       'wash_group_name_i18n', '{}'::jsonb, 'starts', 2, 'loads', 2.38)),
  'by_wash_group: the group, its name and the counts');
select is(pg_temp.val_as('owner', $$select by_wash_group from public.get_off_queue_starts(pg_temp.id('plantA')) where reason = 'urgent'$$), '[]',
  'a reason with no starts: an empty list');
select is(pg_temp.val_as('owner', $$select last_at from public.get_off_queue_starts(pg_temp.id('plantA')) where reason = 'not_ready'$$)::timestamptz,
  (select max(started_at) from public.washer_cycles where machine_id = '60000000-0000-0000-0000-0000000000a2' and voided_at is null),
  'last_at = the latest non-voided off-queue start of that reason');
select is((select pg_temp.counts(pg_temp.id('plantA2'))), '{not_ready:0:0:false,wrong_washer:0:0:false,urgent:1:1.00:true,other:0:0:false}',
  'plant A2 counts only its own start (the org-wide owner reads each plant)');
select is((select pg_temp.counts(pg_temp.id('plantA'), (select production_date - 1 from public.washer_cycles where client_id = pg_temp.cid(21)))),
  '{not_ready:0:0:false,wrong_washer:0:0:false,urgent:0:0:false,other:0:0:false}', 'another production day: zeros');

-- ══ No person identity ═══════════════════════════════════════════════════
select is(pg_get_function_result('public.get_off_queue_starts(uuid, date)'::regprocedure),
  'TABLE(reason text, starts integer, loads numeric, last_at timestamp with time zone, by_wash_group jsonb)',
  'columns: reason, starts, loads, last_at, by_wash_group (no person)');
select ok((select prosrc !~ '(entered_by|staff_id|voided_by|person_name|auth\.uid|profiles|entry_staff)'
             from pg_proc where oid = 'public.get_off_queue_starts(uuid, date)'::regprocedure)
          and pg_temp.val_as('owner', $$select bool_and(k in ('wash_group_id', 'wash_group_name', 'wash_group_name_i18n', 'starts', 'loads'))
                                         from public.get_off_queue_starts(pg_temp.id('plantA')) r,
                                              jsonb_array_elements(r.by_wash_group) e, jsonb_object_keys(e) k$$)::boolean,
  'the read never touches who tapped, and by_wash_group carries only group keys');

select * from finish();
rollback;
