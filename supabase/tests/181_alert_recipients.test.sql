-- Machine-down alert recipients (owner 2026-11-04): memberships.notify_machine_down (default true for
-- owner, false otherwise) and set_alert_recipient (owner only, no oracle).
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(11);

-- Membership id of a fixture user (first one).
create function pg_temp.mid(p_user text) returns uuid language sql stable as $$
  select id from public.memberships where user_id = pg_temp.id(p_user) order by created_at, id limit 1;
$$;
grant execute on function pg_temp.mid(text) to authenticated, anon;
-- A plant-scoped owner of plant A2 only, and a manager on plant A2.
insert into public.memberships (user_id, org_id, plant_id, role) values
  (pg_temp.id('ownerP'), pg_temp.id('orgA'), pg_temp.id('plantA2'), 'owner'),
  (pg_temp.id('a2viewer'), pg_temp.id('orgA'), pg_temp.id('plantA2'), 'manager');

select is((select array_agg(role::text || ':' || notify_machine_down order by role, user_id) from public.memberships where org_id = pg_temp.id('orgA')),
  array['owner:true', 'owner:true', 'manager:false', 'manager:false', 'lead:false', 'viewer:false', 'display:false', 'display:false'],
  'default: owners get alerts, every other role does not');
select is(pg_temp.as_service($$insert into public.memberships (user_id, org_id, plant_id, role, notify_machine_down) values (pg_temp.id('nobody'), pg_temp.id('orgA'), pg_temp.id('plantA'), 'manager', true)$$),
  '1', 'an explicit value on insert is kept');
select is((select notify_machine_down from public.memberships where user_id = pg_temp.id('nobody')), true, 'manager inserted with alerts on');

select is(pg_temp.writes($$select public.set_alert_recipient(pg_temp.mid('manager'), true)$$),
  '{1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'set_alert_recipient: owner only (manager, lead, viewer, display, other tenant: NOT_AUTHORIZED; anon: no EXECUTE)');
select is((select notify_machine_down from public.memberships where id = pg_temp.mid('manager')), true, 'the manager now gets alerts');
select is(array[
  pg_temp.run_as('ownerB', $$select public.set_alert_recipient(gen_random_uuid(), true)$$),
  pg_temp.run_as('ownerP', $$select public.set_alert_recipient(pg_temp.mid('manager'), false)$$),
  pg_temp.run_as('ownerP', $$select public.set_alert_recipient(pg_temp.mid('owner'), false)$$),
  pg_temp.run_as('manager', $$select public.set_alert_recipient(pg_temp.mid('manager'), false)$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED}',
  'no oracle: a missing id; a plant A2 owner on plant A''s membership or the org-wide owner''s; a manager on their own');
select is(pg_temp.val_as('ownerP', $$select (public.set_alert_recipient(pg_temp.mid('a2viewer'), true)).notify_machine_down::text$$),
  'true', 'a plant owner manages alerts for their own plant''s members');
select is(array[
  pg_temp.run_as('owner', $$select public.set_alert_recipient(pg_temp.mid('lead'), true)$$),
  pg_temp.run_as('owner', $$select public.set_alert_recipient(pg_temp.mid('display'), true)$$),
  pg_temp.run_as('owner', $$select public.set_alert_recipient(pg_temp.mid('lead'), false)$$),
  pg_temp.run_as('owner', $$select public.set_alert_recipient(pg_temp.mid('manager'), null)$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,1,VALIDATION_FAILED}', 'only owner/manager memberships can be turned on; null rejected');
update public.memberships set revoked_at = now() where user_id = pg_temp.id('nobody');
select is(pg_temp.run_as('owner', $$select public.set_alert_recipient((select id from public.memberships where user_id = pg_temp.id('nobody')), false)$$),
  'VALIDATION_FAILED', 'a revoked membership is rejected');
select is(pg_temp.val_as('owner', $$select (public.set_alert_recipient(pg_temp.id('owner')::uuid, false))::text$$), 'NOT_AUTHORIZED',
  'a user id is not a membership id (missing → NOT_AUTHORIZED)');
select is(array[pg_temp.run_as('manager', $$select notify_machine_down from public.memberships where plant_id = pg_temp.id('plantA')$$, true),
                pg_temp.run_as('lead', $$select notify_machine_down from public.memberships$$, true)],
  array[(select count(*)::text from public.memberships where plant_id = pg_temp.id('plantA')), '0'],
  'the People screen reads it from memberships (owner/manager); a lead sees no memberships');

select * from finish();
rollback;
