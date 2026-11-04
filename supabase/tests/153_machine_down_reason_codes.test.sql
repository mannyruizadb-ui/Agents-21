-- Machine-down reason codes (owner 2026-11-04): app.machine_down_reason, machine_status_events.reason_code,
-- set_machine_status p_reason_code (free text = optional details, required for other; p_reason alone
-- still works as other), and reason_code on get_machine_status / get_washroom_board with the
-- owner/manager-only hiding of security review L6.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(16);

insert into public.machines (id, org_id, plant_id, area_id, name, kind, active) values
  ('60000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Washer 3', 'washer', true),
  ('60000000-0000-0000-0000-0000000000a4', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Dryer 1', 'dryer', true);
create function pg_temp.cid(n int) returns uuid language sql immutable as $$
  select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;
$$;
grant execute on function pg_temp.cid(int) to authenticated, anon;

select enum_has_labels('app', 'machine_down_reason', array['water_pump','soap_dispenser','wont_start','leaking','other'],
  'preset reasons: water pump, soap dispenser, won''t start, leaking, other');
select is((select array_agg(attname::text order by attnum) from pg_attribute
            where attrelid = 'public.machine_status_result'::regclass and attnum > 0 and not attisdropped),
  array['event_id','machine_id','status','reason','since','changed','reason_code'], 'result type: reason_code added last');

-- ══ set_machine_status ═══════════════════════════════════════════════════
select is(pg_temp.val_as('manager', $$select row((r).status, (r).reason_code, coalesce((r).reason, 'null'), (r).changed)::text
                                        from (select public.set_machine_status(pg_temp.id('machine'), 'down', pg_temp.cid(1), p_reason_code => 'water_pump') r) x$$),
  '(down,water_pump,null,t)', 'down with a preset code and no details');
select is(pg_temp.val_as('owner', $$select row((r).reason_code, (r).changed)::text
                                      from (select public.set_machine_status(pg_temp.id('machine'), 'down', pg_temp.cid(1), p_reason_code => 'leaking') r) x$$),
  '(water_pump,f)', 'idempotent retry returns the recorded code');
select is(pg_temp.val_as('manager', $$select row((r).reason_code, (r).reason)::text
                                        from (select public.set_machine_status('60000000-0000-0000-0000-0000000000a3', 'down', gen_random_uuid(), 'Belt slipping') r) x$$),
  '(other,"Belt slipping")', 'backward compatible: only p_reason → recorded as other with that text as details');
select is(pg_temp.val_as('manager', $$select row((r).reason_code, (r).reason)::text
                                        from (select public.set_machine_status('60000000-0000-0000-0000-0000000000a4', 'down', gen_random_uuid(), ' Lint trap ', 'other') r) x$$),
  '(other,"Lint trap")', 'other with details (trimmed)');
select is(array[
  pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a3', 'up', gen_random_uuid(), p_reason_code => 'leaking')$$),
  pg_temp.run_as('owner', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a4', 'up', gen_random_uuid())$$),
  pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a4', 'down', gen_random_uuid(), p_reason_code => 'other')$$),
  pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a4', 'down', gen_random_uuid(), '  ', 'other')$$),
  pg_temp.run_as('manager', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a4', 'down', gen_random_uuid())$$)],
  array['VALIDATION_FAILED', '1', 'VALIDATION_FAILED', 'VALIDATION_FAILED', 'VALIDATION_FAILED'],
  'rejects: a code on up; other without details (none or blank); down with neither code nor details');
select is(array[
  pg_temp.run_as('lead', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a4', 'down', gen_random_uuid(), p_reason_code => 'wont_start')$$),
  pg_temp.run_as('ownerB', $$select public.set_machine_status('60000000-0000-0000-0000-0000000000a4', 'down', gen_random_uuid(), p_reason_code => 'wont_start')$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED}', 'roles unchanged: lead and another tenant are refused');

-- ══ Table CHECKs ═════════════════════════════════════════════════════════
select is(array[
  pg_temp.as_service($$insert into public.machine_status_events (org_id, plant_id, machine_id, status, client_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), '60000000-0000-0000-0000-0000000000a4', 'down', gen_random_uuid())$$),
  pg_temp.as_service($$insert into public.machine_status_events (org_id, plant_id, machine_id, status, reason_code, client_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), '60000000-0000-0000-0000-0000000000a4', 'down', 'other', gen_random_uuid())$$),
  pg_temp.as_service($$insert into public.machine_status_events (org_id, plant_id, machine_id, status, reason_code, client_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), '60000000-0000-0000-0000-0000000000a4', 'up', 'leaking', gen_random_uuid())$$),
  pg_temp.as_service($$insert into public.machine_status_events (org_id, plant_id, machine_id, status, reason_code, client_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), '60000000-0000-0000-0000-0000000000a4', 'down', 'soap_dispenser', gen_random_uuid())$$)],
  array['23514', '23514', '23514', '1'], 'CHECKs: down needs a code; other needs details; up has no code; a code alone is enough');

-- ══ Reads: same per-role hiding as the free text ═════════════════════════
select is(array[
  pg_temp.val_as('owner',   $$select coalesce(down_reason_code::text, 'null') from public.get_washroom_board(pg_temp.id('wash')) where machine_name = 'Washer 1'$$),
  pg_temp.val_as('manager', $$select coalesce(down_reason_code::text, 'null') from public.get_washroom_board(pg_temp.id('wash')) where machine_name = 'Washer 1'$$),
  pg_temp.val_as('lead',    $$select coalesce(down_reason_code::text, 'null') from public.get_washroom_board(pg_temp.id('wash')) where machine_name = 'Washer 1'$$),
  pg_temp.val_as('viewer',  $$select coalesce(down_reason_code::text, 'null') from public.get_washroom_board(pg_temp.id('wash')) where machine_name = 'Washer 1'$$),
  pg_temp.val_as('display', $$select coalesce(down_reason_code::text, 'null') from public.get_washroom_board(pg_temp.id('wash')) where machine_name = 'Washer 1'$$)],
  array['water_pump', 'water_pump', 'null', 'null', 'null'], 'get_washroom_board: down_reason_code for owner/manager only');
select is(pg_temp.val_as('lead', $$select bool_and(is_down)::text from public.get_washroom_board(pg_temp.id('wash')) where machine_name in ('Washer 1', 'Washer 3')$$),
  'true', 'everyone still sees that the washer is down');
select is(array[
  pg_temp.val_as('owner',  $$select array_agg(machine_name || ':' || coalesce(reason_code::text, '-') order by machine_name)::text from public.get_machine_status(pg_temp.id('plantA'))$$),
  pg_temp.val_as('viewer', $$select array_agg(machine_name || ':' || coalesce(reason_code::text, '-') order by machine_name)::text from public.get_machine_status(pg_temp.id('plantA'))$$)],
  array['{"Dryer 1:soap_dispenser","Washer 1:water_pump","Washer 3:other"}', '{"Dryer 1:-","Washer 1:-","Washer 3:-"}'],
  'get_machine_status: reason_code for owner/manager; null for lead/viewer');
select is(pg_temp.val_as('owner', $$select (status, reason_code)::text from public.get_machine_status(pg_temp.id('plantA')) where machine_name = 'Dryer 1'$$),
  '(down,soap_dispenser)', 'the latest event''s code is returned');
select is(array[has_column_privilege('authenticated', 'public.machine_status_events', 'reason_code', 'select'),
                has_column_privilege('authenticated', 'public.machine_status_events', 'entered_by', 'select')],
  array[false, false], 'no direct read of reason_code or entered_by (reasons only through the RPCs, hidden per role)');
select is((select reason_code::text from public.machine_status_events where client_id = pg_temp.cid(1)),
  'water_pump', 'the code is stored on the event');
select is((select count(*)::int from public.alert_events where kind = 'machine_down' and plant_id = pg_temp.id('plantA')), 3,
  'one alert per machine marked down through the RPC (codes do not change the push hook)');

select * from finish();
rollback;
