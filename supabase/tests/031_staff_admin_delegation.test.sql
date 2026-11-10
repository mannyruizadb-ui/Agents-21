-- A8 owner decision 2026-11-01: the owner may delegate entry-staff management to specific managers
-- (memberships.can_manage_staff → app.can_manage_staff; entry_staff C/U policies; set_staff_pin).
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
-- The entry-PIN RPCs are service_role only since 20261110104605 (asserted in 229_audit_fixes_2026_11_10).
-- This file still exercises their kept-for-history logic as signed-in roles: grant inside this rolled-back transaction.
grant execute on function public.set_staff_pin(uuid, text) to authenticated;
select plan(32);

insert into public.entry_staff (id, org_id, plant_id, display_name) values
  ('b0000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'),  'Ana'),
  ('b0000000-0000-0000-0000-0000000000c1', pg_temp.id('orgA'), pg_temp.id('plantA2'), 'Cleo'),
  ('b0000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'),  'Zed');

-- ── Column + CHECK ───────────────────────────────────────────────────────
select col_not_null('public', 'memberships', 'can_manage_staff', 'memberships.can_manage_staff is not null');
select col_default_is('public', 'memberships', 'can_manage_staff', 'false', 'can_manage_staff defaults to false');
select throws_ok($$update public.memberships set can_manage_staff = true where user_id = pg_temp.id('lead')$$,
  '23514', null, 'CHECK: a lead row cannot carry can_manage_staff');
select throws_ok($$update public.memberships set can_manage_staff = true where user_id = pg_temp.id('owner')$$,
  '23514', null, 'CHECK: an owner row cannot carry can_manage_staff');
select throws_ok($$update public.memberships set can_manage_staff = true where user_id = pg_temp.id('display')$$,
  '23514', null, 'CHECK: a display row cannot carry can_manage_staff');
select is(pg_temp.run_as('owner', $$insert into public.memberships (user_id, org_id, plant_id, role, can_manage_staff)
  values (pg_temp.id('nobody'), pg_temp.id('orgA'), pg_temp.id('plantA2'), 'viewer', true)$$),
  '23514', 'CHECK applies to owner inserts too (viewer + flag rejected)');

-- ── Unflagged manager: same as owner-only (030 still holds) ──────────────
select is(pg_temp.reads($$select 1 where app.can_manage_staff(pg_temp.id('plantA'))$$),
  '{1,0,0,0,0,0,0,42501}', 'app.can_manage_staff: owner only while no manager is flagged; anon cannot call it');
select is(array[pg_temp.run_as('manager', $$insert into public.entry_staff (org_id, plant_id, display_name)
                                             values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Mia')$$),
                pg_temp.run_as('manager', $$update public.entry_staff set active = active where plant_id = pg_temp.id('plantA')$$),
                pg_temp.run_as('manager', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a1', '4821')$$)],
  '{42501,0,NOT_AUTHORIZED}', 'plain manager: entry_staff insert, update and set_staff_pin denied');

-- ── Only the owner sets the flag ─────────────────────────────────────────
select is(pg_temp.run_as('manager', $$update public.memberships set can_manage_staff = true where user_id = pg_temp.id('manager')$$),
  '0', 'a manager cannot grant themselves the flag');
select is(pg_temp.writes($$update public.memberships set can_manage_staff = true
                            where user_id = pg_temp.id('manager') and not can_manage_staff$$),
  '{1,0,0,0,0,0,0,42501}', 'memberships U (incl. the flag) is owner only');
select is((select can_manage_staff from public.memberships where user_id = pg_temp.id('manager')), true, 'owner granted the flag');
select is((select count(*)::int from public.audit_log
            where action = 'memberships.update' and actor_user_id = pg_temp.id('owner')
              and before ->> 'can_manage_staff' = 'false' and after ->> 'can_manage_staff' = 'true'
              and after ->> 'user_id' = pg_temp.id('manager')::text),
  1, 'the flag change is audited (before/after, actor = owner)');

-- ── Flagged manager on plant A ───────────────────────────────────────────
select is(pg_temp.reads($$select 1 where app.can_manage_staff(pg_temp.id('plantA'))$$),
  '{1,1,0,0,0,0,0,42501}', 'app.can_manage_staff: owner + flagged manager');
select is(pg_temp.writes($$insert into public.entry_staff (org_id, plant_id, display_name)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'N-' || substr(md5(random()::text), 1, 8))$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'entry_staff C owner + flagged manager');
select is(pg_temp.run_as('manager', $$update public.entry_staff set home_shift_id = pg_temp.id('finNight') where id = 'b0000000-0000-0000-0000-0000000000a1'$$),
  '1', 'flagged manager edits a person (home shift)');
select is(pg_temp.writes($$update public.entry_staff set active = active where plant_id = pg_temp.id('plantA')$$),
  '{3,3,0,0,0,0,0,42501}', 'entry_staff U owner + flagged manager');
select is(pg_temp.writes($$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a1', '4821')$$),
  '{1,1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'set_staff_pin owner + flagged manager');
select is((select count(*)::int from public.audit_log where action = 'entry_staff.pin_set'
            and entity_id = 'b0000000-0000-0000-0000-0000000000a1' and actor_user_id = pg_temp.id('manager')),
  1, 'a manager''s PIN reset is audited with the manager as actor');
select is(pg_temp.run_as('manager', $$select pin_hash from public.entry_staff$$, true), '42501', 'flagged manager still cannot read pin_hash');
select is(pg_temp.run_as('manager', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a1', '1111')$$),
  'VALIDATION_FAILED', 'flagged manager gets the same PIN rules');

-- ── The flag is per plant ────────────────────────────────────────────────
select is(array[pg_temp.run_as('manager', $$select 1 where app.can_manage_staff(pg_temp.id('plantA2'))$$, true),
                pg_temp.run_as('manager', $$insert into public.entry_staff (org_id, plant_id, display_name)
                                             values (pg_temp.id('orgA'), pg_temp.id('plantA2'), 'Mia')$$),
                pg_temp.run_as('manager', $$update public.entry_staff set active = active where plant_id = pg_temp.id('plantA2')$$),
                pg_temp.run_as('manager', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000c1', '5930')$$)],
  '{0,42501,0,NOT_AUTHORIZED}', 'flagged on plant A: denied on plant A2 of the same org');
select is(array[pg_temp.run_as('manager', $$insert into public.entry_staff (org_id, plant_id, display_name)
                                             values (pg_temp.id('orgB'), pg_temp.id('plantB'), 'Mia')$$),
                pg_temp.run_as('manager', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000b1', '5930')$$)],
  '{42501,NOT_AUTHORIZED}', 'flagged on plant A: denied on another tenant''s plant');

-- ── A flagged manager still has no membership rights ─────────────────────
select is(array[pg_temp.run_as('manager', $$update public.memberships set can_manage_staff = false where user_id = pg_temp.id('manager')$$),
                pg_temp.run_as('manager', $$update public.memberships set revoked_at = now() where user_id = pg_temp.id('viewer')$$),
                pg_temp.run_as('manager', $$insert into public.memberships (user_id, org_id, plant_id, role, can_manage_staff)
                                             values (pg_temp.id('nobody'), pg_temp.id('orgA'), pg_temp.id('plantA'), 'manager', true)$$)],
  '{0,0,42501}', 'flagged manager cannot change or create memberships (no self-service, no new flagged managers)');
select is(pg_temp.run_as('owner', $$update public.memberships set role = 'lead' where user_id = pg_temp.id('manager')$$),
  '23514', 'demoting a flagged manager needs the flag cleared first (CHECK)');

-- ── Revoked membership / flag removed ────────────────────────────────────
update public.memberships set revoked_at = now() where user_id = pg_temp.id('manager');
select is(array[pg_temp.run_as('manager', $$select 1 where app.can_manage_staff(pg_temp.id('plantA'))$$, true),
                pg_temp.run_as('manager', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a1', '4821')$$)],
  '{0,NOT_AUTHORIZED}', 'a revoked flagged membership grants nothing');
update public.memberships set revoked_at = null where user_id = pg_temp.id('manager');
select is(pg_temp.run_as('owner', $$update public.memberships set can_manage_staff = false where user_id = pg_temp.id('manager')$$),
  '1', 'owner removes the flag');
select is(array[pg_temp.run_as('manager', $$insert into public.entry_staff (org_id, plant_id, display_name)
                                             values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Mia')$$),
                pg_temp.run_as('manager', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a1', '4821')$$)],
  '{42501,NOT_AUTHORIZED}', 'without the flag the manager is denied again');

-- ── Org-wide flagged manager ─────────────────────────────────────────────
select lives_ok($$insert into public.memberships (user_id, org_id, plant_id, role, can_manage_staff)
  values (pg_temp.id('nobody'), pg_temp.id('orgA'), null, 'manager', true)$$, 'org-wide manager membership may carry the flag');
select is(array[pg_temp.run_as('nobody', $$select 1 where app.can_manage_staff(pg_temp.id('plantA'))$$, true),
                pg_temp.run_as('nobody', $$select 1 where app.can_manage_staff(pg_temp.id('plantA2'))$$, true),
                pg_temp.run_as('nobody', $$select 1 where app.can_manage_staff(pg_temp.id('plantB'))$$, true)],
  '{1,1,0}', 'org-wide flag covers every plant of the org, not other orgs');
select is(pg_temp.run_as('nobody', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000c1', '5930')$$),
  '1', 'org-wide flagged manager sets a PIN on plant A2');

-- ── Privileges ───────────────────────────────────────────────────────────
select is(array[has_function_privilege('authenticated', 'app.can_manage_staff(uuid)', 'execute'),
                has_function_privilege('anon', 'app.can_manage_staff(uuid)', 'execute'),
                has_function_privilege('public', 'app.can_manage_staff(uuid)', 'execute')],
  array[true, false, false], 'app.can_manage_staff: authenticated only (not anon / PUBLIC)');
select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'app.can_manage_staff(uuid)'::regprocedure),
  'app.can_manage_staff is SECURITY DEFINER with an empty search_path');

select * from finish();
rollback;
