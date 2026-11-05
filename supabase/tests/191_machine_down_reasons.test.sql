-- Owner 2026-11-05: machine-down reasons are per-plant data (machine_down_reasons), owner-editable;
-- set_machine_status accepts only an active reason of the machine's plant; labels come back with the
-- same owner/manager-only hiding.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(17);

select is(pg_temp.reads($$select 1 from public.machine_down_reasons where plant_id = pg_temp.id('plantA')$$),
  '{5,5,5,5,5,0,0,42501}', 'every plant role and the display read the plant''s reasons; no cross-tenant; anon nothing');
select is((select array[label_i18n ->> 'es', requires_details::text] from public.machine_down_reasons where plant_id = pg_temp.id('plantA') and code = 'wont_start'),
  array['No arranca', 'false'], 'defaults carry Spanish labels');
select is((select array_agg(label_i18n ->> 'es' order by sort_order) from public.machine_down_reasons r
             join public.plants p on p.id = r.plant_id and p.name = 'Miami'),
  array['Bomba de agua', 'Dispensador de jabón', 'No arranca', 'Gotea', 'Otro'], 'the ADB plant has the 5 defaults');
select is((select requires_details from public.machine_down_reasons where plant_id = pg_temp.id('plantA') and code = 'other'), true,
  'other requires details');

-- ══ Owner-only edits ═════════════════════════════════════════════════════
select is(pg_temp.writes($$insert into public.machine_down_reasons (org_id, plant_id, code, label_i18n, sort_order)
                             values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'r_' || substr(md5(random()::text), 1, 6), '{"en":"Belt","es":"Correa"}', 50)$$),
  '{1,42501,42501,42501,42501,42501,42501,42501}', 'add a reason: owner only');
select is(pg_temp.writes($$update public.machine_down_reasons set label_i18n = '{"en":"Pump","es":"Bomba"}' where plant_id = pg_temp.id('plantA') and code = 'water_pump'$$),
  '{1,0,0,0,0,0,0,42501}', 'relabel: owner only (anon: no privilege)');
select is(array[
  pg_temp.run_as('owner', $$update public.machine_down_reasons set code = 'pump' where plant_id = pg_temp.id('plantA') and code = 'water_pump'$$),
  pg_temp.run_as('owner', $$delete from public.machine_down_reasons where plant_id = pg_temp.id('plantA')$$),
  pg_temp.run_as('owner', $$update public.machine_down_reasons set plant_id = pg_temp.id('plantA2') where plant_id = pg_temp.id('plantA')$$)],
  '{42501,42501,42501}', 'the code, the plant and deletes are not client-writable (deactivate instead)');
select is(array[
  pg_temp.run_as('owner', $$insert into public.machine_down_reasons (org_id, plant_id, code, label_i18n) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'x1', '{"es":"Sin inglés"}')$$),
  pg_temp.run_as('owner', $$insert into public.machine_down_reasons (org_id, plant_id, code, label_i18n) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'x2', '{"en":"Ok","xx":"Bad"}')$$),
  pg_temp.run_as('owner', $$insert into public.machine_down_reasons (org_id, plant_id, code, label_i18n) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Bad Code', '{"en":"Ok"}')$$),
  pg_temp.run_as('owner', $$insert into public.machine_down_reasons (org_id, plant_id, code, label_i18n) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'leaking', '{"en":"Dup"}')$$)],
  '{23514,VALIDATION_FAILED,23514,23505}', 'rejects: no English label, an unknown language, a bad code, a duplicate code');
select is(pg_temp.run_as('owner', $$insert into public.machine_down_reasons (org_id, plant_id, code, label_i18n, requires_details) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'belt', '{"en":"Belt","es":"Correa"}', true)$$),
  '1', 'the owner adds "belt" (details required)');

-- ══ set_machine_status uses the plant's active reasons ═══════════════════
select is(array[
  pg_temp.run_as('manager', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), p_reason_code => 'belt')$$),
  pg_temp.run_as('manager', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), p_reason_code => 'nonexistent')$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED}', 'a custom reason that requires details needs them; an unknown code is rejected');
update public.machine_down_reasons set active = false where plant_id = pg_temp.id('plantA') and code = 'leaking';
select is(pg_temp.run_as('manager', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), p_reason_code => 'leaking')$$),
  'VALIDATION_FAILED', 'an inactive reason cannot be chosen');
insert into public.machine_down_reasons (org_id, plant_id, code, label_i18n) values (pg_temp.id('orgB'), pg_temp.id('plantB'), 'b_only', '{"en":"B only"}');
select is(pg_temp.run_as('manager', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), p_reason_code => 'b_only')$$),
  'VALIDATION_FAILED', 'another plant''s reason cannot be used');
select is(pg_temp.as_service($$insert into public.machine_status_events (org_id, plant_id, machine_id, status, reason_code, client_id) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('machine'), 'down', 'b_only', gen_random_uuid())$$),
  '23503', 'the composite FK keeps reasons within the plant on any write path');
select is(pg_temp.run_as('manager', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), 'Belt snapped', 'belt')$$),
  '1', 'down with the custom reason and details');

-- ══ Labels in the reads, hidden like the code ════════════════════════════
select is(array[
  pg_temp.val_as('owner', $$select down_reason_label_i18n ->> 'es' from public.get_washroom_board(pg_temp.id('wash'))$$),
  pg_temp.val_as('lead',  $$select coalesce(down_reason_label_i18n ->> 'es', 'null') from public.get_washroom_board(pg_temp.id('wash'))$$)],
  array['Correa', 'null'], 'get_washroom_board: the label for owner/manager; null for lead');
select is(array[
  pg_temp.val_as('manager', $$select reason_code || ':' || (reason_label_i18n ->> 'en') from public.get_machine_status(pg_temp.id('plantA')) where machine_name = 'Washer 1'$$),
  pg_temp.val_as('viewer',  $$select coalesce(reason_label_i18n::text, 'null') from public.get_machine_status(pg_temp.id('plantA')) where machine_name = 'Washer 1'$$)],
  array['belt:Belt', 'null'], 'get_machine_status: code + label for managers; null for viewers');

-- A new plant gets the defaults.
insert into public.plants (id, org_id, name, enabled_languages) values ('20000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), 'Plant New', '{en}');
select is((select count(*)::int from public.machine_down_reasons where plant_id = '20000000-0000-0000-0000-0000000000d1'), 5,
  'a new plant starts with the 5 default reasons');

select * from finish();
rollback;
