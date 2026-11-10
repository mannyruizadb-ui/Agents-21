-- Shared plant iPad (owner 2026-11-10): register / revoke (owner only), the name list and the login
-- lookup (service role only, live token only, managers and leads only, never owners).
begin;
\ir _fixtures.psql
select plan(24);

-- A second org-A manager who is ALSO an owner: must never be listed.
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-0000000000d1', 'boss@a.test');
insert into public.memberships (user_id, org_id, plant_id, role) values
  ('aaaaaaaa-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'manager'),
  ('aaaaaaaa-0000-0000-0000-0000000000d1', pg_temp.id('orgA'), pg_temp.id('plantA2'), 'owner');
-- Security review L2/L4 cases: a plant A manager who owns ANOTHER org; a plant A manager with no name;
-- a plant A lead whose membership was revoked; a manager only on plant A2.
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-0000000000d2', 'crossowner@a.test'),
  ('aaaaaaaa-0000-0000-0000-0000000000d3', 'noname@a.test'),
  ('aaaaaaaa-0000-0000-0000-0000000000d4', 'gone@a.test'),
  ('aaaaaaaa-0000-0000-0000-0000000000d5', 'a2only@a.test');
insert into public.memberships (user_id, org_id, plant_id, role, revoked_at) values
  ('aaaaaaaa-0000-0000-0000-0000000000d2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'manager', null),
  ('aaaaaaaa-0000-0000-0000-0000000000d2', pg_temp.id('orgB'), null, 'owner', null),
  ('aaaaaaaa-0000-0000-0000-0000000000d3', pg_temp.id('orgA'), pg_temp.id('plantA'), 'manager', null),
  ('aaaaaaaa-0000-0000-0000-0000000000d4', pg_temp.id('orgA'), pg_temp.id('plantA'), 'lead', now()),
  ('aaaaaaaa-0000-0000-0000-0000000000d5', pg_temp.id('orgA'), pg_temp.id('plantA2'), 'manager', null);
insert into public.profiles (user_id, full_name) values
  (pg_temp.id('lead'), 'Lead A'),
  ('aaaaaaaa-0000-0000-0000-0000000000d1', 'Boss'),
  ('aaaaaaaa-0000-0000-0000-0000000000d2', 'Cross Owner'),
  ('aaaaaaaa-0000-0000-0000-0000000000d3', null),
  ('aaaaaaaa-0000-0000-0000-0000000000d4', 'Gone'),
  ('aaaaaaaa-0000-0000-0000-0000000000d5', 'Plant A2 Only');

-- ══ register: owner only ═════════════════════════════════════════════════
select is(array[
  pg_temp.run_as('manager', $$select public.register_shared_device(pg_temp.id('plantA'), 'Plant iPad')$$),
  pg_temp.run_as('lead', $$select public.register_shared_device(pg_temp.id('plantA'), 'Plant iPad')$$),
  pg_temp.run_as('ownerB', $$select public.register_shared_device(pg_temp.id('plantA'), 'Plant iPad')$$),
  pg_temp.run_as('anon', $$select public.register_shared_device(pg_temp.id('plantA'), 'Plant iPad')$$)],
  array['NOT_AUTHORIZED', 'NOT_AUTHORIZED', 'NOT_AUTHORIZED', '42501'],
  'manager, lead, another org''s owner and anon cannot register a shared device');
select is(array[
  pg_temp.run_as('owner', $$select public.register_shared_device(pg_temp.id('plantA'), '')$$),
  pg_temp.run_as('owner', $$select public.register_shared_device(pg_temp.id('plantA'), repeat('x', 41))$$),
  pg_temp.run_as('owner', $$select public.register_shared_device(null, 'iPad')$$)],
  array['VALIDATION_FAILED', 'VALIDATION_FAILED', 'VALIDATION_FAILED'], 'label 1-40 and a plant are required');

select set_config('test.token', pg_temp.val_as('owner', $$select token from public.register_shared_device(pg_temp.id('plantA'), ' Plant iPad ')$$), true);
select ok(current_setting('test.token') ~ '^[0-9a-f]{64}$', 'the owner gets a 64-hex token once');
select is((select label from public.shared_devices limit 1), 'Plant iPad', 'the label is trimmed');
select set_config('test.second', pg_temp.val_as('owner', $$select id::text from public.register_shared_device(pg_temp.id('plantA'), 'Second')$$), true);
select is((select label from public.shared_devices where id = current_setting('test.second')::uuid),
  'Second', 'the returned id is the new row''s id');
select is(pg_temp.val_as('owner', $$select public.revoke_shared_device((select id from public.shared_devices where label = 'Second'))::text$$), 'true', 'cleanup: second device revoked');
select is((select token_hash from public.shared_devices where label = 'Plant iPad'),
  encode(extensions.digest(current_setting('test.token'), 'sha256'), 'hex'), 'only the SHA-256 of the token is stored');
select is(array[
  (select count(*)::int from public.audit_log where entity = 'shared_devices' and action = 'shared_devices.insert'),
  (select count(*)::int from public.audit_log where entity = 'shared_devices' and action = 'shared_devices.revoke'),
  (select count(*)::int from public.audit_log where entity = 'shared_devices' and (after ? 'token_hash' or after::text like '%' || current_setting('test.token') || '%'))],
  array[2, 1, 0], 'register and revoke are audited, never with the token or its hash');
select is(pg_temp.val_as('owner', $$select public.revoke_shared_device((select id from public.shared_devices where label = 'Second'))::text$$),
  'false', 'revoking a revoked device changes nothing');
select is(array[
  has_function_privilege('anon', 'app.shared_device_token_hash(text)', 'execute'),
  has_function_privilege('authenticated', 'app.shared_device_token_hash(text)', 'execute')],
  array[false, false], 'clients cannot call the token hash helper');

-- ══ who reads the rows ═══════════════════════════════════════════════════
select is(pg_temp.reads($$select id, label, revoked_at from public.shared_devices where label = 'Plant iPad'$$),
  array['1','0','0','0','0','0','0','42501'], 'owners of the plant read the list; nobody else');
select is(pg_temp.run_as('owner', $$select token_hash from public.shared_devices$$),
  '42501', 'nobody reads token_hash, not even the owner');
select is(array[
  pg_temp.run_as('owner', $$insert into public.shared_devices (org_id, plant_id, label, token_hash, created_by) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'x', repeat('a', 64), pg_temp.id('owner'))$$),
  pg_temp.run_as('owner', $$update public.shared_devices set revoked_at = null$$),
  pg_temp.run_as('owner', $$delete from public.shared_devices$$)],
  array['42501', '42501', '42501'], 'no direct writes (RPCs only)');

-- ══ the name list: service role only ═════════════════════════════════════
select is(array[
  has_function_privilege('anon', 'public.shared_device_people(text)', 'execute'),
  has_function_privilege('authenticated', 'public.shared_device_people(text)', 'execute'),
  has_function_privilege('anon', 'public.shared_device_login(text,uuid)', 'execute'),
  has_function_privilege('authenticated', 'public.shared_device_login(text,uuid)', 'execute'),
  has_function_privilege('service_role', 'public.shared_device_people(text)', 'execute'),
  has_function_privilege('service_role', 'public.shared_device_login(text,uuid)', 'execute')],
  array[false, false, false, false, true, true], 'the list and the login lookup are service-role only');

select is((select array_agg(display_name order by display_name) from public.shared_device_people(current_setting('test.token'))),
  array['Lead A', 'Manager A'],
  'lists plant A''s named managers and leads only: never owners (any plant, any org), viewers, displays, the nameless, revoked or other-plant memberships');
select is((select count(*)::int from public.shared_device_people(repeat('0', 64))), 0, 'an unknown token lists nobody');
select is((select count(*)::int from public.shared_device_people('not-a-token')), 0, 'a malformed token lists nobody');
select ok((select last_used_at is not null from public.shared_devices where label = 'Plant iPad'), 'listing marks the device used');

select set_config('test.mgr', (select id::text from public.memberships where user_id = pg_temp.id('manager')), true);
select is(array[
  public.shared_device_login(current_setting('test.token'), current_setting('test.mgr')::uuid),
  coalesce(public.shared_device_login(current_setting('test.token'), (select id from public.memberships where user_id = pg_temp.id('owner'))), '-'),
  coalesce(public.shared_device_login(current_setting('test.token'), (select id from public.memberships where user_id = pg_temp.id('viewer'))), '-'),
  coalesce(public.shared_device_login(repeat('0', 64), current_setting('test.mgr')::uuid), '-')],
  array['manager@a.test', '-', '-', '-'], 'the login is given only for a listed person on a live device');

-- A deactivated (banned) manager drops off the list.
update auth.users set banned_until = now() + interval '1 day' where id = pg_temp.id('manager');
select is((select array_agg(display_name) from public.shared_device_people(current_setting('test.token'))), array['Lead A'], 'a deactivated account is not listed');
update auth.users set banned_until = null where id = pg_temp.id('manager');

-- ══ other plants ══════════════════════════════════════════════════════════
select set_config('test.tokenB', pg_temp.val_as('ownerB', $$select token from public.register_shared_device(pg_temp.id('plantB'), 'B iPad')$$), true);
select is(array[
  (select count(*)::text from public.shared_device_people(current_setting('test.tokenB'))),
  coalesce(public.shared_device_login(current_setting('test.tokenB'), current_setting('test.mgr')::uuid), '-')],
  array['0', '-'], 'plant B''s device lists nobody from plant A and signs none of them in');
select is(pg_temp.run_as('owner', $$select public.register_shared_device(pg_temp.id('plantA'), 'x'), public.register_shared_device(pg_temp.id('plantA'), 'x'), public.register_shared_device(pg_temp.id('plantA'), 'x'), public.register_shared_device(pg_temp.id('plantA'), 'x'), public.register_shared_device(pg_temp.id('plantA'), 'x')$$),
  'VALIDATION_FAILED', 'at most 5 live devices per plant');

-- ══ revoke ═══════════════════════════════════════════════════════════════
select is(array[
  pg_temp.run_as('manager', $$select public.revoke_shared_device((select id from public.shared_devices where label = 'Plant iPad'))$$),
  pg_temp.run_as('ownerB', $$select public.revoke_shared_device((select id from public.shared_devices where label = 'Plant iPad'))$$)],
  array['NOT_AUTHORIZED', 'NOT_AUTHORIZED'], 'only the plant''s owner revokes');
select is(array[
  pg_temp.val_as('owner', $$select public.revoke_shared_device((select id from public.shared_devices where label = 'Plant iPad'))::text$$),
  (select count(*)::text from public.shared_device_people(current_setting('test.token'))),
  coalesce(public.shared_device_login(current_setting('test.token'), current_setting('test.mgr')::uuid), '-')],
  array['true', '0', '-'], 'a revoked device lists nobody and signs in nobody');

select * from finish();
rollback;
