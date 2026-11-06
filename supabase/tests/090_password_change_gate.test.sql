-- A4 (owner decision 2026-11-03; security review M2): while the JWT carries
-- app_metadata.must_change_password = true, the role helpers answer false, so RLS and role-checked
-- RPCs deny. With the flag false or absent, behavior is unchanged.
begin;
\ir _fixtures.psql
select plan(26);

insert into public.finished_goods_entries (org_id, plant_id, area_id, item_type_id, loose_pieces, occurred_at, entered_by, client_id) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), pg_temp.id('mat'), 5, pg_temp.ny('2026-11-03 11:30'), pg_temp.id('owner'), gen_random_uuid());
insert into public.entry_staff (id, org_id, plant_id, display_name) values
  ('b0000000-0000-0000-0000-0000000000a9', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Pat');

-- Like pg_temp.run_as, with app_metadata in the claims. p_flag: 'true', 'false' or null (absent).
create function pg_temp.run_flag(p_user text, p_flag text, p_sql text, p_count boolean default true)
returns text language plpgsql as $$
declare
  n bigint;
begin
  perform set_config('request.jwt.claims',
    case when p_flag is null
      then json_build_object('sub', pg_temp.id(p_user), 'role', 'authenticated')
      else json_build_object('sub', pg_temp.id(p_user), 'role', 'authenticated',
                             'app_metadata', json_build_object('must_change_password', p_flag::boolean))
    end::text, true);
  perform set_config('role', 'authenticated', true);
  if p_count then
    execute 'select count(*) from (' || p_sql || ') x' into n;
  else
    execute p_sql;
    get diagnostics n = row_count;
  end if;
  reset role;
  return n::text;
exception when others then
  return case when sqlstate = 'P0001' then sqlerrm else sqlstate end;
end;
$$;

-- Each check under flag true / false / absent.
create function pg_temp.flags(p_user text, p_sql text, p_count boolean default true) returns text[]
language sql as $$
  select array[pg_temp.run_flag(p_user, 'true', p_sql, p_count),
               pg_temp.run_flag(p_user, 'false', p_sql, p_count),
               pg_temp.run_flag(p_user, null, p_sql, p_count)];
$$;

-- ── The function itself ──────────────────────────────────────────────────
select has_function('app', 'password_ok', '{}'::name[], 'app.password_ok() exists');
select function_returns('app', 'password_ok', '{}'::name[], 'boolean', 'app.password_ok() returns boolean');
select is(pg_temp.flags('owner', $$select 1 where app.password_ok()$$), '{0,1,1}',
  'password_ok: false only while the flag is true');
select ok(has_function_privilege('authenticated', 'app.password_ok()', 'execute'), 'authenticated may execute password_ok');
select ok(not has_function_privilege('anon', 'app.password_ok()', 'execute'), 'anon may not execute password_ok');
select ok(not has_function_privilege('anon', 'app.has_role(uuid, app.member_role[])', 'execute'), 'anon may not execute has_role');
select ok(not has_function_privilege('anon', 'app.has_org_role(uuid, app.member_role[])', 'execute'), 'anon may not execute has_org_role');
select ok(not has_function_privilege('anon', 'app.can_manage_staff(uuid)', 'execute'), 'anon may not execute can_manage_staff');
select is(pg_temp.run_as('anon', $$select app.password_ok()$$), '42501', 'anon cannot call password_ok');

-- ── Helpers ──────────────────────────────────────────────────────────────
select is(pg_temp.flags('owner', $$select 1 where app.has_role(pg_temp.id('plantA'), '{owner}')$$), '{0,1,1}',
  'has_role (org-wide owner): false while flagged, true otherwise');
select is(pg_temp.flags('manager', $$select 1 where app.has_role(pg_temp.id('plantA'), '{manager}')$$), '{0,1,1}',
  'has_role (plant manager): false while flagged, true otherwise');
select is(pg_temp.flags('owner', $$select 1 where app.has_org_role(pg_temp.id('orgA'), '{owner}')$$), '{0,1,1}',
  'has_org_role: false while flagged, true otherwise');
select is(pg_temp.flags('owner', $$select 1 where app.can_manage_staff(pg_temp.id('plantA'))$$), '{0,1,1}',
  'can_manage_staff: false while flagged, true otherwise');
select is(pg_temp.flags('lead', $$select 1 where app.has_role(pg_temp.id('plantA'), '{owner}')$$), '{0,0,0}',
  'has_role still answers by role (lead is never owner)');

-- ── Tables through RLS ───────────────────────────────────────────────────
select is(pg_temp.flags('owner', $$select 1 from public.plants where id = pg_temp.id('plantA')$$), '{0,1,1}',
  'plants: 0 rows while flagged');
select is(pg_temp.flags('owner', $$select 1 from public.memberships where org_id = pg_temp.id('orgA')$$),
  array['0', (select count(*)::text from public.memberships where org_id = pg_temp.id('orgA')),
              (select count(*)::text from public.memberships where org_id = pg_temp.id('orgA'))],
  'memberships: 0 rows while flagged, all of org A otherwise');
select is(pg_temp.flags('manager', $$select 1 from public.finished_goods_entries$$), '{0,1,1}',
  'finished_goods_entries: 0 rows while flagged');
select is(pg_temp.flags('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', gen_random_uuid(), pg_temp.id('gNapkin'), p_is_rewash => true)$$, false),
  '{NOT_AUTHORIZED,1,1}', 'M2 write RPCs (create_queue_item) are denied while flagged');
select is(pg_temp.flags('owner', $$update public.memberships set revoked_at = revoked_at where user_id = pg_temp.id('lead')$$, false),
  '{0,1,1}', 'memberships update reaches no rows while flagged');

-- ── Role-checked RPCs (they raise NOT_AUTHORIZED when the helper says no) ─
select is(pg_temp.run_flag('owner', 'true', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a9', '4821')$$, false),
  'NOT_AUTHORIZED', 'set_staff_pin refused while flagged');
select is(pg_temp.run_flag('owner', 'false', $$select public.set_staff_pin('b0000000-0000-0000-0000-0000000000a9', '4821')$$, false),
  '1', 'set_staff_pin works with the flag false');
select is(pg_temp.run_flag('owner', 'true', $$select public.create_pairing_code(pg_temp.id('wash'), 'TV A')$$, false),
  'NOT_AUTHORIZED', 'create_pairing_code refused while flagged');
select is(pg_temp.run_flag('owner', null, $$select public.create_pairing_code(pg_temp.id('wash'), 'TV A')$$, false),
  '1', 'create_pairing_code works with the flag absent');

-- ── Not gated ────────────────────────────────────────────────────────────
select is(pg_temp.flags('owner', $$select 1 from public.profiles where user_id = (select auth.uid())$$), '{1,1,1}',
  'own profile stays readable while flagged');
select is(pg_temp.run_flag('owner', 'true', $$update public.profiles set language = 'es' where user_id = (select auth.uid())$$, false),
  '1', 'own profile stays updatable while flagged (language choice)');
select ok(pg_temp.run_flag('owner', 'true', $$select 1 from public.languages$$)::int > 0, 'languages stay readable while flagged');

select * from finish();
rollback;
