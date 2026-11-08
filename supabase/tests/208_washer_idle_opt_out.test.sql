-- Owner 2026-11-06 (C): memberships.notify_washer_idle. Owners who turn it off stop getting washer_idle
-- (push and Alerts tab); the manager(s) on duty ALWAYS get it. set_washer_idle_alert: owners only, owner
-- memberships only, and since 2026-11-07 only the owner's OWN memberships (self-only).
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(14);

create function pg_temp.mid(p_user text) returns uuid language sql stable as $$
  select id from public.memberships where user_id = pg_temp.id(p_user) order by created_at, id limit 1;
$$;
grant execute on function pg_temp.mid(text) to authenticated, anon;
create function pg_temp.idle_recipients() returns uuid[] language sql stable as $$
  select coalesce(array_agg(distinct u order by u), '{}') from public.alert_events a cross join lateral app.alert_recipient_users(a) u
   where a.kind = 'washer_idle' and a.plant_id = pg_temp.id('plantA');
$$;
create function pg_temp.sees_idle(p_user text) returns text language sql as $$
  select pg_temp.val_as(p_user, $q$select (count(*) filter (where kind = 'washer_idle'))::text from public.get_my_alerts(pg_temp.id('plantA'))$q$);
$$;
-- The second owner (the father), plant-scoped; the manager on duty now (spare-area shift).
insert into public.memberships (user_id, org_id, plant_id, role) values (pg_temp.id('ownerP'), pg_temp.id('orgA'), pg_temp.id('plantA'), 'owner');
insert into public.shifts (id, org_id, plant_id, area_id, name, start_local, end_local, days_of_week, active) values
  ('90000000-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Now', '00:00', '01:00', '{0}', false);
insert into public.shift_instances (org_id, plant_id, area_id, shift_id, business_date, starts_at, ends_at) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '90000000-0000-0000-0000-0000000000d1', '2000-01-01', now() - interval '2 hours', now() + interval '2 hours');
insert into public.manager_shift_assignments (org_id, plant_id, membership_id, shift_id)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.mid('manager'), '90000000-0000-0000-0000-0000000000d1');
-- An idle washer in the spare area with work waiting.
insert into public.machines (id, org_id, plant_id, area_id, name, kind) values
  ('60000000-0000-0000-0000-0000000000e1', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), 'Washer S', 'washer');
update public.wash_formulas set cycle_minutes = 30 where id = pg_temp.id('formula');
insert into public.washer_cycles (org_id, plant_id, area_id, machine_id, wash_group_id, wash_formula_id, started_at, load_count, source, client_id)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), '60000000-0000-0000-0000-0000000000e1', pg_temp.id('gNapkin'), pg_temp.id('formula'), now() - interval '60 minutes', 1, 'manual', gen_random_uuid());
insert into public.queue_items (org_id, plant_id, area_id, wash_group_id, qty, unit, position, created_by, client_id)
values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('spare'), pg_temp.id('gNapkin'), 2, 'load', 1, pg_temp.id('owner'), gen_random_uuid());
select is(app.generate_washer_idle_alerts(), 1, 'Washer S idle');

select is((select array_agg(distinct notify_washer_idle) from public.memberships), array[true], 'default: on for everyone');
select is(pg_temp.idle_recipients(), (select array_agg(u order by u) from unnest(array[pg_temp.id('owner'), pg_temp.id('manager'), pg_temp.id('ownerP')]) u),
  'default: both owners and the manager on duty');

-- ══ set_washer_idle_alert ════════════════════════════════════════════════
select is(array[
  pg_temp.run_as('manager', $$select public.set_washer_idle_alert(pg_temp.mid('owner'), false)$$),
  pg_temp.run_as('lead', $$select public.set_washer_idle_alert(pg_temp.mid('owner'), false)$$),
  pg_temp.run_as('viewer', $$select public.set_washer_idle_alert(pg_temp.mid('owner'), false)$$),
  pg_temp.run_as('display', $$select public.set_washer_idle_alert(pg_temp.mid('owner'), false)$$),
  pg_temp.run_as('ownerB', $$select public.set_washer_idle_alert(pg_temp.mid('owner'), false)$$),
  pg_temp.run_as('ownerB', $$select public.set_washer_idle_alert(gen_random_uuid(), false)$$),
  pg_temp.run_as('anon', $$select public.set_washer_idle_alert(pg_temp.mid('owner'), false)$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'owners only; cross-tenant and unknown ids give the same NOT_AUTHORIZED');
select is(array[
  pg_temp.run_as('owner', $$select public.set_washer_idle_alert(pg_temp.mid('manager'), false)$$),
  pg_temp.run_as('owner', $$select public.set_washer_idle_alert(pg_temp.mid('ownerP'), false)$$),
  pg_temp.run_as('ownerP', $$select public.set_washer_idle_alert(pg_temp.mid('ownerP'), null)$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,VALIDATION_FAILED}',
  'self-only (2026-11-07): an owner cannot change a manager''s or the other owner''s (the father''s) setting; p_notify required');
select is(pg_temp.val_as('ownerP', $$select (public.set_washer_idle_alert(pg_temp.mid('ownerP'), false)).notify_washer_idle::text$$), 'false',
  'the other owner (the father) turns his own off');
select is(array[pg_temp.run_as('ownerP', $$select public.set_washer_idle_alert(pg_temp.mid('owner'), false)$$),
                pg_temp.val_as('owner', $$select (public.set_washer_idle_alert(pg_temp.mid('owner'), false)).notify_washer_idle::text$$)],
  '{NOT_AUTHORIZED,false}',
  'an org-wide owner membership needs an org owner (same rule as set_alert_recipient): a plant-scoped owner cannot change it; the owner turns their own off');
select is(pg_temp.val_as('owner', $$select string_agg(notify_washer_idle::text, ',') from public.memberships where role = 'owner' and plant_id is not distinct from null$$),
  'false', 'the setting is readable on the People screen (memberships)');

-- ══ Both owners off: the manager on duty still gets it ═══════════════════
select is(pg_temp.idle_recipients(), array[pg_temp.id('manager')], 'push: only the manager on duty');
select is(array[pg_temp.sees_idle('owner'), pg_temp.sees_idle('ownerP'), pg_temp.sees_idle('manager')], array['0', '0', '1'],
  'Alerts tab: the owners no longer see it; the manager on duty does');
update public.memberships set notify_washer_idle = false where user_id = pg_temp.id('manager');
select is(array[pg_temp.idle_recipients()::text, pg_temp.sees_idle('manager')], array[array[pg_temp.id('manager')]::text, '1'],
  'the flag never silences the manager on duty (safeguard)');
update public.manager_shift_assignments set active = false;
select is(pg_temp.idle_recipients(), '{}'::uuid[], 'nobody on duty and both owners off: nobody (owner''s choice)');

select is(pg_temp.val_as('ownerP', $$select (public.set_washer_idle_alert(pg_temp.mid('ownerP'), true)).notify_washer_idle::text$$), 'true', 'turned back on');
select is(array[pg_temp.idle_recipients()::text, pg_temp.sees_idle('ownerP'), pg_temp.sees_idle('owner')], array[array[pg_temp.id('ownerP')]::text, '1', '0'],
  'the owner who turned it back on gets it again; the other stays off');

select * from finish();
rollback;
