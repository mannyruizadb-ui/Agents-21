-- Owner decisions 2026-11-06 (washer taps): a START on a washer that is still running needs
-- p_confirm_running (else WASHER_RUNNING), and undo_washer_load works only within 5 minutes of the tap
-- being recorded (created_at). Bug context: a stray second START on a running washer took a load off
-- the queue with nothing actually washing.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(27);

-- Napkins wash on the fixture formula (30 min); Mats have no formula (cycle time unknown).
update public.wash_formulas set cycle_minutes = 30 where id = pg_temp.id('formula');
update public.wash_groups set wash_formula_id = pg_temp.id('formula') where id = pg_temp.id('gNapkin');
insert into public.machines (id, org_id, plant_id, area_id, name, kind, active, load_factor) values
  ('60000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 2', 'washer', true, 1.00),
  ('60000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 3', 'washer', true, 1.00);

create function pg_temp.cid(n int) returns uuid language sql immutable as $$
  select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;
$$;
create function pg_temp.cyc(n int) returns uuid language sql stable as $$
  select id from public.washer_cycles where client_id = pg_temp.cid(n);
$$;
create function pg_temp.q(n int) returns uuid language sql stable as $$
  select id from public.queue_items where client_id = pg_temp.cid(n);
$$;
grant execute on function pg_temp.cid(int), pg_temp.cyc(int), pg_temp.q(int) to authenticated, anon;
create function pg_temp.qstate(n int) returns text[] language sql stable as $$
  select array[status::text, loads_started::text] from public.queue_items where id = pg_temp.q(n);
$$;
-- Like run_as, but returns "CODE|detail" on error (the detail names the expected end).
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

-- ── Signature: one function for PostgREST, same grants as before ──────────
select is((select count(*)::int from pg_catalog.pg_proc where proname = 'start_washer_load' and pronamespace = 'public'::regnamespace),
  1, 'start_washer_load has exactly one signature (the 5-argument one is dropped)');
select ok(has_function_privilege('authenticated', 'public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean)', 'execute')
          and has_function_privilege('service_role', 'public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean)', 'execute')
          and not has_function_privilege('anon', 'public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean)', 'execute'),
  'EXECUTE: authenticated and service_role only (not anon / public)');
select ok(obj_description('public.start_washer_load(uuid, uuid, uuid, uuid, timestamptz, boolean)'::regprocedure, 'pg_proc') like '%WASHER_RUNNING%'
          and obj_description('public.undo_washer_load(uuid, text)'::regprocedure, 'pg_proc') like '%within 5 minutes%',
  'comments document WASHER_RUNNING and the 5-minute undo window');

-- ── Queue: napkins ×3 assigned to Washer 1 (Washers 2 and 3 run off-queue loads) ──
select is(pg_temp.run_as('owner', $$select public.create_queue_item(pg_temp.id('wash'), 3, 'load', pg_temp.cid(1), pg_temp.id('gNapkin'), p_assigned_machine_id => pg_temp.id('machine'))$$),
  '1', 'queue: napkins ×3 on Washer 1');

-- ── Confirm-required path ─────────────────────────────────────────────────
select is(pg_temp.val_as('lead', $$select (public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(101))).queue_item_id$$),
  pg_temp.q(1)::text, 'an idle washer starts without a confirmation');
select is(pg_temp.writes($$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid())$$),
  '{WASHER_RUNNING,WASHER_RUNNING,WASHER_RUNNING,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'a second START on the running washer: WASHER_RUNNING for owner/manager/lead; viewer, display and other tenant still NOT_AUTHORIZED (role check first, no oracle); anon no EXECUTE');
select is(pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(102), p_confirm_running => false)$$),
  'WASHER_RUNNING', 'explicit p_confirm_running => false: WASHER_RUNNING');
select is(pg_temp.err_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid())$$),
  'WASHER_RUNNING|machine_id: still running until '
    || to_char((now() + interval '30 minutes') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '; confirm to start another',
  'the detail names the expected end (started_at + cycle_minutes, UTC)');
select is(array[(pg_temp.qstate(1))[2],
                (select count(*)::text from public.washer_cycles where machine_id = pg_temp.id('machine'))],
  array['1', '1'], 'refused STARTs took nothing off the queue and wrote no cycle');
select is(pg_temp.val_as('viewer', $$select status from public.get_washroom_board(pg_temp.id('wash')) where machine_name = 'Washer 1'$$),
  'running', 'the board shows the same washer as running');

-- Idempotent retry of a saved tap is unaffected by the guard.
select is(pg_temp.val_as('lead', $$select (public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(101))).duplicate$$),
  'true', 'retry of the already-saved tap (same client_id) on the running washer: duplicate=true, no confirmation needed');

-- confirm=true succeeds and advances the queue.
select is(pg_temp.val_as('lead', $$select (public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(102), p_confirm_running => true)).queue_item_id$$),
  pg_temp.q(1)::text, 'p_confirm_running => true: the START is accepted');
select is(pg_temp.qstate(1), array['in_progress', '2'], 'and the queue advances (loads_started 2)');
select is(pg_temp.val_as('lead', $$select (public.start_washer_load(pg_temp.id('machine'), pg_temp.cid(102), p_confirm_running => true)).duplicate$$),
  'true', 'a confirmed tap retried: duplicate, nothing advances twice');

-- ── Unknown cycle time never blocks ──────────────────────────────────────
select is(array[
  pg_temp.val_as('lead', $$select (public.start_washer_load('60000000-0000-0000-0000-0000000000a3', pg_temp.cid(201), null, pg_temp.id('gMat'))).duplicate$$),
  pg_temp.val_as('lead', $$select (public.start_washer_load('60000000-0000-0000-0000-0000000000a3', pg_temp.cid(202), null, pg_temp.id('gMat'))).duplicate$$)],
  '{false,false}', 'Mats (no cycle minutes): back-to-back STARTs need no confirmation');

-- ── Ready / finished washer (past expected end) ──────────────────────────
select is(pg_temp.val_as('lead', $$select (public.start_washer_load('60000000-0000-0000-0000-0000000000a2', pg_temp.cid(301), null, pg_temp.id('gNapkin'))).duplicate$$),
  'false', 'Washer 2: napkins started');
update public.washer_cycles set started_at = now() - interval '31 minutes' where id = pg_temp.cyc(301);
select is(pg_temp.val_as('lead', $$select (public.start_washer_load('60000000-0000-0000-0000-0000000000a2', pg_temp.cid(302), null, pg_temp.id('gNapkin'))).duplicate$$),
  'false', 'a washer past its expected end (ready) starts without a confirmation');
update public.washer_cycles set started_at = now() - interval '30 minutes' where id = pg_temp.cyc(302);
update public.washer_cycles set started_at = now() - interval '62 minutes' where id = pg_temp.cyc(301);
select is(pg_temp.val_as('lead', $$select (public.start_washer_load('60000000-0000-0000-0000-0000000000a2', pg_temp.cid(303), null, pg_temp.id('gNapkin'))).duplicate$$),
  'false', 'expected end exactly at the tap time counts as ready');

-- ── A voided running cycle does not block ────────────────────────────────
select is(pg_temp.val_as('lead', $$select (public.undo_washer_load(pg_temp.cyc(303))).duplicate$$),
  'false', 'the running Washer 2 tap is undone (voided)');
select is(pg_temp.val_as('lead', $$select (public.start_washer_load('60000000-0000-0000-0000-0000000000a2', pg_temp.cid(304), null, pg_temp.id('gNapkin'))).duplicate$$),
  'false', 'a voided running cycle does not block the next START');

-- ── Offline tap time overlapping a later live cycle ──────────────────────
select is(pg_temp.run_as('lead', $$select public.start_washer_load('60000000-0000-0000-0000-0000000000a2', gen_random_uuid(), null, pg_temp.id('gNapkin'), now() - interval '10 minutes')$$),
  'WASHER_RUNNING', 'an offline tap whose time falls before a live cycle''s expected end needs a confirmation too');

-- ── Other washers and tenants are unaffected ─────────────────────────────
select is(pg_temp.run_as('ownerB', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), p_confirm_running => true)$$),
  'NOT_AUTHORIZED', 'p_confirm_running never bypasses the role check (other tenant)');

-- ── undo_washer_load: 5-minute window on created_at ──────────────────────
update public.washer_cycles set created_at = now() - interval '4 minutes' where id = pg_temp.cyc(102);
select is(pg_temp.val_as('lead', $$select (public.undo_washer_load(pg_temp.cyc(102))).duplicate$$),
  'false', 'undo 4 minutes after the tap was recorded: allowed');
select is(pg_temp.qstate(1), array['in_progress', '1'], 'the load goes back to the queue item');
update public.washer_cycles set created_at = now() - interval '5 minutes' where id = pg_temp.cyc(302);
select is(pg_temp.val_as('lead', $$select (public.undo_washer_load(pg_temp.cyc(302))).duplicate$$),
  'false', 'undo exactly 5 minutes after: allowed (boundary)');
update public.washer_cycles set created_at = now() - interval '6 minutes' where id = pg_temp.cyc(101);
select is(pg_temp.run_as('lead', $$select public.undo_washer_load(pg_temp.cyc(101))$$),
  'OUT_OF_RANGE_TIMESTAMP', 'undo 6 minutes after the tap was recorded: OUT_OF_RANGE_TIMESTAMP');
select is((select voided_at is null from public.washer_cycles where id = pg_temp.cyc(101)),
  true, 'the refused undo left the cycle live');

select * from finish();
rollback;
