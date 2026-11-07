-- §4.7 matrix + validation: languages, organizations, plants, profiles, memberships, audit_log, app_events.
-- Matrix arrays are [owner, manager, lead, viewer, display, display-without-device, owner of B, anon];
-- each value is a row count, an app error code, or a SQLSTATE (42501 = permission/RLS denied).
begin;
\ir _fixtures.psql
select plan(44);

-- languages: global R for every signed-in user; nobody writes.
select is(pg_temp.reads($$select 1 from public.languages$$), '{3,3,3,3,3,3,3,42501}', 'languages R');
select is(pg_temp.writes($$insert into public.languages (code, name_native) values ('fr', 'Français')$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'languages C denied');

-- organizations: R members (display with device), U owner.
select is(pg_temp.reads($$select 1 from public.organizations where id = pg_temp.id('orgA')$$),
  '{1,1,1,1,1,0,0,42501}', 'organizations R (own org only)');
select is(pg_temp.writes($$update public.organizations set name = name || '!' where id = pg_temp.id('orgA')$$),
  '{1,0,0,0,0,0,0,42501}', 'organizations U owner only');
select is(pg_temp.writes($$insert into public.organizations (name, slug) values ('X', 'x-' || substr(md5(random()::text), 1, 8))$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'organizations C denied');
select throws_ok($$insert into public.organizations (name, slug) values ('Bad', 'Bad Slug')$$, '23514', null, 'org slug CHECK');

-- plants: R all roles (display own plant), U owner.
select is(pg_temp.reads($$select 1 from public.plants where id = pg_temp.id('plantA')$$),
  '{1,1,1,1,1,0,0,42501}', 'plants R (own plant; not cross-tenant)');
select is(pg_temp.writes($$update public.plants set estimate_amber_minutes = 100 where id = pg_temp.id('plantA')$$),
  '{1,0,0,0,0,0,0,42501}', 'plants U owner only');
select is(pg_temp.writes($$insert into public.plants (org_id, name) values (pg_temp.id('orgA'), 'P2')$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'plants C denied');
select is(pg_temp.run_as('owner', $$update public.plants set timezone = 'Mars/Olympus' where id = pg_temp.id('plantA')$$),
  'VALIDATION_FAILED', 'plant timezone must exist in pg_timezone_names');
select throws_ok($$insert into public.plants (org_id, name, timezone) values (pg_temp.id('orgA'), 'P3', 'Nowhere/City')$$,
  'P0001', 'VALIDATION_FAILED', 'plant insert with unknown timezone rejected');
select is(pg_temp.run_as('owner', $$update public.plants set enabled_languages = '{en,xx}' where id = pg_temp.id('plantA')$$),
  'VALIDATION_FAILED', 'enabled_languages must exist in languages');
select is(pg_temp.run_as('owner', $$update public.plants set enabled_languages = '{es}' where id = pg_temp.id('plantA')$$),
  'VALIDATION_FAILED', 'default_language must be enabled');

-- profiles: own row R U; no client insert; display accounts excluded (security L7).
insert into public.profiles (user_id, full_name, language) values (pg_temp.id('display'), 'Washroom TV', 'es');
select is(pg_temp.reads($$select 1 from public.profiles$$), '{1,1,0,0,0,0,1,42501}', 'profiles R own row only');
select is(pg_temp.run_as('manager', $$update public.profiles set full_name = 'M'$$), '1', 'profiles U own row');
select is(pg_temp.run_as('manager', $$update public.profiles set full_name = 'X' where user_id = pg_temp.id('owner')$$),
  '0', 'profiles U of another user affects nothing');
select is(pg_temp.run_as('lead', $$insert into public.profiles (user_id) values (pg_temp.id('lead'))$$), '42501', 'profiles C denied');
select is(pg_temp.run_as('display', $$update public.profiles set full_name = 'X'$$), '0', 'L7: a display cannot update even its own profile');
select is(pg_temp.run_as('owner', $$update public.profiles set language = 'ht'$$), 'VALIDATION_FAILED',
  'profile language must be enabled for the user''s plant');
select is(pg_temp.run_as('owner', $$update public.profiles set a11y_prefs = '{"undo_seconds":30,"text_scale":1.5,"high_contrast":true}'$$),
  '1', 'valid a11y_prefs accepted');
select is(pg_temp.run_as('owner', $$update public.profiles set a11y_prefs = '{"undo_seconds":5}'$$), '23514', 'a11y undo_seconds 10–60');
select is(pg_temp.run_as('owner', $$update public.profiles set a11y_prefs = '{"text_scale":3}'$$), '23514', 'a11y text_scale 1.0–2.0');
select is(pg_temp.run_as('owner', $$update public.profiles set a11y_prefs = '{"reduce_motion":"yes"}'$$), '23514', 'a11y other keys boolean');

-- memberships: owner R C U, manager R (plant-scoped rows).
select is(pg_temp.reads($$select 1 from public.memberships where org_id = pg_temp.id('orgA')$$),
  '{6,5,0,0,0,0,0,42501}', 'memberships R owner (all) / manager (plant rows)');
select is(pg_temp.writes($$insert into public.memberships (user_id, org_id, plant_id, role)
                            values (pg_temp.id('nobody'), pg_temp.id('orgA'), pg_temp.id('plantA'), 'viewer')$$),
  '{1,42501,42501,42501,42501,42501,42501,42501}', 'memberships C owner only (no cross-tenant grants)');
select is(pg_temp.writes($$update public.memberships set revoked_at = now() where user_id = pg_temp.id('nobody')$$),
  '{1,0,0,0,0,0,0,42501}', 'memberships U owner only');

-- Attack (a): a plant-scoped manager of A sees nothing of plant A2 in the same org.
insert into public.memberships (user_id, org_id, plant_id, role) values
  (pg_temp.id('a2viewer'), pg_temp.id('orgA'), pg_temp.id('plantA2'), 'viewer'),
  (pg_temp.id('ownerP'),   pg_temp.id('orgA'), pg_temp.id('plantA'),  'owner');
select is(array[pg_temp.run_as('owner', $$select 1 from public.memberships where plant_id = pg_temp.id('plantA2')$$, true),
                pg_temp.run_as('manager', $$select 1 from public.memberships where plant_id = pg_temp.id('plantA2')$$, true),
                pg_temp.run_as('manager', $$update public.memberships set role = 'manager' where plant_id = pg_temp.id('plantA2')$$),
                pg_temp.run_as('manager', $$select 1 from public.plants where id = pg_temp.id('plantA2')$$, true)],
  '{1,0,0,0}', 'plant A manager: no read/write of plant A2 memberships or plant (org-wide owner can)');
-- Attack (c): a plant-scoped owner cannot widen their own membership to org-wide.
select is(array[pg_temp.run_as('ownerP', $$update public.memberships set plant_id = null where user_id = pg_temp.id('ownerP')$$),
                pg_temp.run_as('ownerP', $$insert into public.memberships (user_id, org_id, plant_id, role)
                                            values (pg_temp.id('nobody'), pg_temp.id('orgA'), null, 'owner')$$),
                pg_temp.run_as('ownerP', $$update public.memberships set plant_id = pg_temp.id('plantA2') where user_id = pg_temp.id('ownerP')$$)],
  '{42501,42501,42501}', 'plant-scoped owner cannot grant org-wide or other-plant access (WITH CHECK rejects)');
select is((select plant_id from public.memberships where user_id = pg_temp.id('ownerP')), pg_temp.id('plantA'), 'plant-scoped owner membership unchanged');
select is(pg_temp.run_as('ownerP', $$update public.organizations set name = 'Hijack' where id = pg_temp.id('orgA')$$), '0',
  'plant-scoped owner cannot update the organization');

-- audit_log: owner/manager R; nobody writes (app.audit() only).
select is(pg_temp.reads($$select 1 from public.audit_log where org_id = pg_temp.id('orgA') limit 1$$),
  '{1,0,0,0,0,0,0,42501}', 'audit_log R: owner only (security review 2026-11-06 H1)');
select is(pg_temp.writes($$insert into public.audit_log (org_id, action, entity) values (pg_temp.id('orgA'), 'x', 'x')$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'audit_log C denied');
select is(pg_temp.writes($$update public.audit_log set action = 'x'$$), '{0,0,0,0,0,0,0,42501}', 'audit_log U denied');
select is(array[pg_temp.run_as('owner', $$select 1 from public.audit_log where entity = 'organizations' and org_id = pg_temp.id('orgA')$$, true),
                pg_temp.run_as('manager', $$select 1 from public.audit_log where entity = 'organizations'$$, true)],
  '{2,0}', 'org-level audit rows: org-wide owner R, plant manager not');
select is((select array[actor_user_id::text, (before ->> 'name'), (after ->> 'name')] from public.audit_log
            where entity = 'organizations' and action = 'organizations.update'),
  array[pg_temp.id('owner')::text, 'Org A', 'Org A!'], 'audit row records actor and before/after');

-- app_events: any plant member C own events (incl. paired display); owner/manager R.
select is(pg_temp.writes($$insert into public.app_events (org_id, plant_id, user_id, name)
                            values (pg_temp.id('orgA'), pg_temp.id('plantA'), (select auth.uid()), 'test_event')$$),
  '{1,1,1,1,1,42501,42501,42501}', 'app_events C by plant members (display needs a device)');
select is(pg_temp.run_as('lead', $$insert into public.app_events (org_id, plant_id, user_id, name)
                                   values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('owner'), 'spoof')$$),
  '42501', 'app_events C with another user_id denied');
select is(pg_temp.run_as('lead', $$insert into public.app_events (org_id, plant_id, user_id, name)
                                   values (pg_temp.id('orgB'), pg_temp.id('plantB'), (select auth.uid()), 'x')$$),
  '42501', 'app_events C into another tenant denied');
select throws_ok($$insert into public.app_events (org_id, plant_id, name) values (pg_temp.id('orgB'), pg_temp.id('plantA'), 'x')$$,
  '23503', null, 'app_events plant must belong to its org');
select is(pg_temp.reads($$select 1 from public.app_events where org_id = pg_temp.id('orgA')$$),
  '{5,5,0,0,0,0,0,42501}', 'app_events R owner/manager');
select is(pg_temp.writes($$update public.app_events set name = 'x'$$), '{0,0,0,0,0,0,0,42501}', 'app_events U denied');
-- Security L5: device_id must be the caller's own device; props are bounded.
select is(array[pg_temp.run_as('display', $$insert into public.app_events (org_id, plant_id, user_id, device_id, name)
                  values (pg_temp.id('orgA'), pg_temp.id('plantA'), (select auth.uid()), pg_temp.id('device'), 'display_online')$$),
                pg_temp.run_as('lead', $$insert into public.app_events (org_id, plant_id, user_id, device_id, name)
                  values (pg_temp.id('orgA'), pg_temp.id('plantA'), (select auth.uid()), pg_temp.id('device'), 'spoof')$$),
                pg_temp.run_as('lead', $$insert into public.app_events (org_id, plant_id, user_id, name, props)
                  values (pg_temp.id('orgA'), pg_temp.id('plantA'), (select auth.uid()), 'big',
                          jsonb_build_object('x', (select string_agg(md5(random()::text), '') from generate_series(1, 300))))$$)],
  '{1,42501,42501}', 'app_events: own device only; props ≤ 4 KB');
select is(pg_temp.run_as('display', $$select 1 from public.profiles$$, true), '0', 'L7: a display cannot read its profile');
select is(pg_temp.run_as('display', $$select 1 from public.app_events$$, true), '0', 'display cannot read analytics');

select * from finish();
rollback;
