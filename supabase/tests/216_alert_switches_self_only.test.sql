-- Alert switches are self-only for owners (owner 2026-11-07; 20261107021209) and off_queue_start is gone
-- (20261107021207). set_alert_level / set_washer_idle_alert: own owner memberships only; set_alert_recipient:
-- managers' memberships as before, owner memberships only one's own; the memberships trigger closes the
-- direct table path (UPDATE and INSERT). Statements run directly here have service-role semantics.
begin;
\ir _fixtures.psql
select plan(16);

-- The second owner (the father), plant-scoped.
insert into public.memberships (user_id, org_id, plant_id, role) values (pg_temp.id('ownerP'), pg_temp.id('orgA'), pg_temp.id('plantA'), 'owner');
create function pg_temp.mid(p text) returns uuid language sql stable security definer as $$
  select m.id from public.memberships m where m.user_id = pg_temp.id(p) and m.revoked_at is null order by m.created_at, m.id limit 1;
$$;
grant execute on function pg_temp.mid(text) to authenticated, anon;

-- ══ RPCs ═════════════════════════════════════════════════════════════════
select is(array[
  pg_temp.run_as('owner',  $$select public.set_alert_level(pg_temp.mid('ownerP'), 'customer_delivery', 'off')$$),
  pg_temp.run_as('ownerP', $$select public.set_alert_level(pg_temp.mid('owner'), 'customer_delivery', 'off')$$),
  pg_temp.run_as('owner',  $$select public.set_alert_level(pg_temp.mid('owner'), 'customer_delivery', 'off')$$),
  pg_temp.run_as('ownerP', $$select public.set_alert_level(pg_temp.mid('ownerP'), 'account_locked', 'quiet')$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,1,1}', 'set_alert_level: an owner changes only their own levels (the org owner cannot change the father''s, nor he theirs)');
select is(array[
  pg_temp.run_as('owner',  $$select public.set_washer_idle_alert(pg_temp.mid('ownerP'), false)$$),
  pg_temp.run_as('ownerP', $$select public.set_washer_idle_alert(pg_temp.mid('owner'), false)$$),
  pg_temp.run_as('ownerP', $$select public.set_washer_idle_alert(pg_temp.mid('ownerP'), false)$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,1}', 'set_washer_idle_alert: own only');
select is(array[
  pg_temp.run_as('owner',  $$select public.set_alert_recipient(pg_temp.mid('manager'), false)$$),
  pg_temp.run_as('owner',  $$select public.set_alert_recipient(pg_temp.mid('ownerP'), false)$$),
  pg_temp.run_as('ownerP', $$select public.set_alert_recipient(pg_temp.mid('owner'), false)$$),
  pg_temp.run_as('ownerP', $$select public.set_alert_recipient(pg_temp.mid('ownerP'), false)$$),
  pg_temp.run_as('ownerB', $$select public.set_alert_recipient(pg_temp.mid('manager'), true)$$),
  pg_temp.run_as('manager', $$select public.set_alert_recipient(pg_temp.mid('manager'), true)$$)],
  '{1,NOT_AUTHORIZED,NOT_AUTHORIZED,1,NOT_AUTHORIZED,NOT_AUTHORIZED}',
  'set_alert_recipient: owners still switch managers'' machine-down alerts; another owner''s is theirs alone; other tenants and managers refused');
select is((select array[(alert_levels ->> 'customer_delivery'), notify_washer_idle::text, notify_machine_down::text] from public.memberships where id = pg_temp.mid('owner')),
  array['off', 'true', 'true'], 'the org owner''s settings: only their own change stuck (the father''s attempts changed nothing)');

-- ══ Direct table writes (owner UPDATE policy + table grant): the trigger ═
select is(array[
  pg_temp.run_as('owner', $$update public.memberships set alert_levels = '{}' where id = pg_temp.mid('ownerP')$$),
  pg_temp.run_as('owner', $$update public.memberships set notify_washer_idle = true where id = pg_temp.mid('ownerP')$$),
  pg_temp.run_as('owner', $$update public.memberships set notify_machine_down = true where id = pg_temp.mid('ownerP')$$),
  pg_temp.run_as('ownerP', $$update public.memberships set alert_levels = '{}' where id = pg_temp.mid('ownerP')$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,1}',
  'direct UPDATE: an owner cannot write another owner''s alert_levels, washer-idle or machine-down flag; their own is fine');
select is(array[
  pg_temp.run_as('owner', $$update public.memberships set notify_machine_down = true where id = pg_temp.mid('manager')$$),
  pg_temp.run_as('owner', $$update public.memberships set alert_levels = '{"rewash_added":"push"}' where id = pg_temp.mid('manager')$$),
  pg_temp.run_as('owner', $$update public.memberships set can_enter_load_out = true where id = pg_temp.mid('manager')$$),
  pg_temp.run_as('manager', $$update public.memberships set alert_levels = '{}' where id = pg_temp.mid('owner')$$)],
  '{1,NOT_AUTHORIZED,1,0}',
  'a manager''s machine-down flag and other columns stay owner-editable; their alert levels are not (owner-only settings); managers update nothing (RLS)');
select is(array[
  pg_temp.run_as('owner', $$insert into public.memberships (user_id, org_id, plant_id, role, alert_levels) values (pg_temp.id('lead'), pg_temp.id('orgA'), pg_temp.id('plantA2'), 'owner', '{"customer_delivery":"off"}')$$),
  pg_temp.run_as('owner', $$insert into public.memberships (user_id, org_id, plant_id, role, notify_washer_idle) values (pg_temp.id('lead'), pg_temp.id('orgA'), pg_temp.id('plantA2'), 'owner', false)$$),
  pg_temp.run_as('owner', $$insert into public.memberships (user_id, org_id, plant_id, role) values (pg_temp.id('lead'), pg_temp.id('orgA'), pg_temp.id('plantA2'), 'owner')$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,1}', 'direct INSERT for another person: alert settings must keep their defaults');
select is(pg_temp.as_service($$update public.memberships set alert_levels = '{}', notify_washer_idle = true where id = pg_temp.mid('ownerP')$$), '1',
  'the service role (manage-users, migrations) is not limited');
select is((select pg_get_expr(d.adbin, d.adrelid)::text from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
            where d.adrelid = 'public.memberships'::regclass and a.attname = 'alert_levels'),
  quote_literal(app.default_alert_levels()::text) || '::jsonb', 'the column default equals app.default_alert_levels() (the guard compares against it)');
select is(array[has_function_privilege('authenticated', 'app.guard_member_alert_settings()', 'execute'),
                has_function_privilege('authenticated', 'app.default_alert_levels()', 'execute')],
  '{f,f}', 'the trigger function and the default helper are internal');

-- ══ off_queue_start is gone ══════════════════════════════════════════════
select is(array[
  pg_temp.as_service($$insert into public.alert_events (org_id, plant_id, kind, subject_id, recipients) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'off_queue_start', gen_random_uuid(), '{}')$$),
  pg_temp.as_service($$update public.memberships set alert_levels = '{"off_queue_start":"quiet"}' where id = pg_temp.mid('owner')$$)],
  '{23514,23514}', 'the kind CHECK and the levels CHECK refuse off_queue_start');
select ok((select convalidated from pg_constraint where conname = 'alert_events_kind_check' and conrelid = 'public.alert_events'::regclass),
  'the alert_events kind CHECK is validated (no off_queue_start rows exist)');
select is((select count(*)::int from public.memberships where alert_levels ? 'off_queue_start'), 0, 'no membership carries an off_queue_start level');
select is(pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), gen_random_uuid(), p_wash_group_id => pg_temp.id('gMat'))$$), '1',
  'an off-queue start …');
select is((select count(*)::int from public.alert_events where plant_id = pg_temp.id('plantA')), 0, '… writes no alert at all');
select ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname in ('public', 'app') and p.prosrc like '%off_queue_start%'),
  'no function mentions off_queue_start any more');

select * from finish();
rollback;
