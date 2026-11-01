-- A7: devices, pairing_codes, app.my_device(), create_pairing_code; D13 display rules.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(27);

-- A second device (finishing TV) so "own row only" is observable.
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000009', 'device-3@devices.local');
insert into public.devices (id, org_id, plant_id, user_id, area_id, name) values
  ('40000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'),
   'aaaaaaaa-0000-0000-0000-000000000009', pg_temp.id('fin'), 'Finishing TV');

select is(pg_temp.run_as('display', $$select 1 where (app.my_device()).id = pg_temp.id('device')$$, true), '1', 'my_device() returns the caller''s device');
select is(pg_temp.run_as('manager', $$select 1 where (app.my_device()).id is null$$, true), '1', 'my_device() is null for a non-device user');

-- devices: owner/manager R C U, lead R, display own row R.
select is(pg_temp.reads($$select 1 from public.devices where plant_id = pg_temp.id('plantA')$$), '{2,2,2,0,1,0,0,0}', 'devices R (display: own row)');
select is(pg_temp.run_as('display', $$select 1 from public.devices where id = pg_temp.id('device')$$, true), '1', 'display reads its own row');
select is(pg_temp.writes($$update public.devices set name = name where plant_id = pg_temp.id('plantA')$$), '{2,2,0,0,0,0,0,42501}',
  'devices U owner/manager (name/area/languages/revoke only)');
select is(pg_temp.writes($$insert into public.devices (org_id, plant_id, user_id, area_id, name)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), (select auth.uid()), pg_temp.id('wash'), 'TV')$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'security M1: devices C only via pair-device (service role)');
select is(pg_temp.run_as('manager', $$insert into public.devices (org_id, plant_id, user_id, area_id, name)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('ownerB'), pg_temp.id('wash'), 'Hijack')$$), '42501',
  'attack (d): a manager cannot bind a device row to another tenant''s user');
select is(array[pg_temp.run_as('owner', $$update public.devices set user_id = pg_temp.id('owner') where id = pg_temp.id('device')$$),
                pg_temp.run_as('owner', $$update public.devices set plant_id = pg_temp.id('plantA2') where id = pg_temp.id('device')$$),
                pg_temp.run_as('manager', $$update public.devices set area_id = pg_temp.id('fin') where id = pg_temp.id('device')$$),
                pg_temp.run_as('manager', $$update public.devices set area_id = pg_temp.id('wash') where id = pg_temp.id('device')$$)],
  '{42501,42501,1,1}', 'device user/plant are immutable for clients; area may move within the plant');
select is(pg_temp.run_as('owner', $$update public.devices set display_languages = '{ht}' where id = pg_temp.id('device')$$),
  'VALIDATION_FAILED', 'display languages must be enabled for the plant');
select is(pg_temp.run_as('owner', $$update public.devices set display_languages = '{es,en,es}' where id = pg_temp.id('device')$$),
  '23514', 'a display shows 1–2 languages');
select throws_ok($$insert into public.devices (org_id, plant_id, user_id, area_id, name)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('nobody'), pg_temp.id('washB'), 'X')$$, '23503', null,
  'device area must belong to its plant');
select col_is_fk('public', 'audit_log', 'actor_device_id', 'audit_log.actor_device_id references devices');

-- create_pairing_code (owner/manager).
select is(pg_temp.run_as('manager', $$select 1 from public.create_pairing_code(pg_temp.id('wash'), 'Washroom TV 2') c
                                      where c.code ~ '^[A-HJ-NP-Z2-9]{6}$' and c.expires_at = now() + interval '15 minutes'$$, true),
  '1', 'manager gets a 6-char code valid 15 min');
select is(pg_temp.run_as('owner', $$select 1 from generate_series(1, 50) g
                                    cross join lateral public.create_pairing_code(pg_temp.id('fin'), 'TV ' || g) c
                                    where c.code ~ '^[A-HJ-NP-Z2-9]{6}$'$$, true), '50', '50 codes, all from the unambiguous alphabet');
select is((select count(distinct code)::int from public.pairing_codes), 51, 'codes are unique');
select is((select array[created_by::text, area_id::text, plant_id::text, device_name] from public.pairing_codes where device_name = 'Washroom TV 2'),
  array[pg_temp.id('manager')::text, pg_temp.id('wash')::text, pg_temp.id('plantA')::text, 'Washroom TV 2'], 'code row bound to area, plant and creator');
select is(pg_temp.writes($$select public.create_pairing_code(pg_temp.id('wash'), 'TV')$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'create_pairing_code owner/manager only');
update public.areas set active = false where id = pg_temp.id('spare');
select is(array[pg_temp.run_as('manager', $$select public.create_pairing_code(pg_temp.id('wash'), '')$$),
                pg_temp.run_as('manager', $$select public.create_pairing_code(pg_temp.id('wash'), ' TV')$$),
                pg_temp.run_as('manager', $$select public.create_pairing_code(pg_temp.id('spare'), 'TV')$$),
                pg_temp.run_as('manager', $$select public.create_pairing_code(pg_temp.id('washB'), 'TV')$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,NOT_AUTHORIZED}', 'bad name / inactive area / other tenant rejected');

-- pairing_codes table: owner/manager R C U, lead R.
insert into public.pairing_codes (code, org_id, plant_id, area_id, device_name, created_by, expires_at, consumed_at)
values ('HJKMNP', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Fixed', pg_temp.id('owner'), now() + interval '15 minutes', now());
select is(pg_temp.reads($$select 1 from public.pairing_codes where code = 'HJKMNP'$$), '{1,1,1,0,0,0,0,0}', 'pairing_codes R');
select is(pg_temp.writes($$insert into public.pairing_codes (code, org_id, plant_id, area_id, device_name, created_by, expires_at)
  values (substr(translate(upper(md5(random()::text)), '01', '23'), 1, 6), pg_temp.id('orgA'), pg_temp.id('plantA'),
          pg_temp.id('wash'), 'TV', (select auth.uid()), now() + interval '15 minutes')$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'security M1: pairing_codes C only via create_pairing_code');
select is(pg_temp.writes($$update public.pairing_codes set expires_at = now() + interval '1 day' where code = 'HJKMNP'$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'security M1: no client updates to pairing codes');
select is(pg_temp.run_as('manager', $$update public.pairing_codes set consumed_at = null where code = 'HJKMNP'$$), '42501',
  'attack (e): a consumed code cannot be revived');
select throws_ok($$insert into public.pairing_codes (code, org_id, plant_id, area_id, device_name, created_by, expires_at)
  values ('ABCDE0', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'X', pg_temp.id('owner'), now())$$, '23514', null,
  'codes never contain 0/O/1/I');

-- Attack (b): a display whose device is in plant A but whose display membership is in plant A2
-- reads nothing in either plant (D13 needs both in the same plant).
insert into public.memberships (user_id, org_id, plant_id, role) values
  (pg_temp.id('display_split'), pg_temp.id('orgA'), pg_temp.id('plantA2'), 'display');
insert into public.devices (org_id, plant_id, user_id, area_id, name) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('display_split'), pg_temp.id('wash'), 'Split TV');
select is(array[pg_temp.run_as('display_split', $$select 1 from public.areas where plant_id = pg_temp.id('plantA2')$$, true),
                pg_temp.run_as('display_split', $$select 1 from public.areas where plant_id = pg_temp.id('plantA')$$, true),
                pg_temp.run_as('display_split', $$select 1 from public.item_types$$, true)],
  '{0,0,0}', 'device in plant A + display membership in A2 → nothing in A2 (or A)');

-- D13: a display without a device row, or with a revoked device, reads nothing.
select is(pg_temp.run_as('display_nodev', $$select 1 from public.areas$$, true), '0', 'display membership without a device reads nothing');
update public.devices set revoked_at = now() where id = pg_temp.id('device');
select is(pg_temp.run_as('display', $$select 1 from public.areas$$, true), '0', 'revoked device reads nothing');
select is(pg_temp.run_as('display', $$select 1 where (app.my_device()).id is null$$, true), '1', 'my_device() ignores revoked devices');

select * from finish();
rollback;
