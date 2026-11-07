-- Security review of 312ca2e, follow-ups (20261107010316, 20261107010437):
--   b. record_customer_delivery throttle (10 per plant per account per 10 minutes; retries never count)
--   c. customer_deliveries.client_id unique per plant (no cross-tenant "already used")
--   d. anon has no privileges on any public table, view or sequence (now or by default)
--   e. estimate_entered batches: lock before the insert, window anchored on the first estimate
begin;
\ir _fixtures.psql
select plan(21);

insert into public.entry_staff (id, org_id, plant_id, display_name, pin_hash) values
  ('b0000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Ben', extensions.crypt('1470', extensions.gen_salt('bf'))),
  ('b0000000-0000-0000-0000-0000000000b2', pg_temp.id('orgB'), pg_temp.id('plantB'), 'Bea', extensions.crypt('2580', extensions.gen_salt('bf')));
insert into public.customers (id, org_id, plant_id, name) values
  ('c1000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'AA Test'),
  ('c1000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), 'B Customer');
insert into public.wash_groups (id, org_id, plant_id, customer_id, name, loads_per_bin, allow_bin_estimates, active) values
  ('71000000-0000-0000-0000-0000000aa0a1', pg_temp.id('orgA'), pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1', 'Kitchen towels', 1.5, true, true),
  ('71000000-0000-0000-0000-0000000aa0b1', pg_temp.id('orgB'), pg_temp.id('plantB'), 'c1000000-0000-0000-0000-0000000000b1', 'B towels', null, false, true);
create function pg_temp.ben() returns uuid language sql as $$
  select (public.start_staff_session('b0000000-0000-0000-0000-0000000000a2', '1470')).staff_session_id;
$$;
create function pg_temp.bea() returns uuid language sql as $$
  select (public.start_staff_session('b0000000-0000-0000-0000-0000000000b2', '2580')).staff_session_id;
$$;
-- One delivery on plant A (1 bin of Kitchen towels) with client id p_client, as the caller, with Ben's PIN.
create function pg_temp.deliver(p_client uuid) returns text language sql as $$
  select format($q$select (public.record_customer_delivery(pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1',
                  '[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":1}]', %L, pg_temp.ben())).duplicate$q$, p_client);
$$;
grant execute on function pg_temp.ben(), pg_temp.bea(), pg_temp.deliver(uuid) to authenticated, anon;

-- ══ d. anon: no table privileges ═════════════════════════════════════════
select is(
  (select coalesce(array_agg(c.relname::text order by c.relname), '{}')
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')),
  '{}'::text[], 'anon has no privilege on any public table or view');
select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
             join pg_attribute a on true
    where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'f') and a.attrelid = c.oid and a.attnum > 0
      and not a.attisdropped and has_column_privilege('anon', c.oid, a.attnum, 'SELECT,INSERT,UPDATE,REFERENCES')),
  0, 'anon has no column privilege on any public table or view');
select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'S'
      and case when c.relkind = 'S' then has_sequence_privilege('anon', c.oid, 'USAGE,SELECT,UPDATE') else false end),
  0, 'anon has no privilege on any public sequence');
select is(
  (select count(*)::int from pg_default_acl d join pg_namespace n on n.oid = d.defaclnamespace
             cross join lateral aclexplode(d.defaclacl) x
    where n.nspname = 'public' and d.defaclrole = 'postgres'::regrole and x.grantee = 'anon'::regrole),
  0, 'future tables, sequences and functions created by postgres (migrations) grant anon nothing');
select is(pg_temp.run_as('anon', $$insert into public.wash_groups (org_id, plant_id, name) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Probe')$$),
  '42501', 'anon insert probe on wash_groups with a REAL plant: 42501 (was VALIDATION_FAILED, which told that the plant exists)');
select is(array[
  pg_temp.run_as('anon', $$insert into public.wash_groups (org_id, plant_id, name) values (gen_random_uuid(), gen_random_uuid(), 'Probe')$$),
  pg_temp.run_as('anon', $$select 1 from public.plants$$, true),
  pg_temp.run_as('anon', $$select 1 from public.sign_in_lockouts$$, true)],
  '{42501,42501,42501}', 'anon: a made-up plant and any read answer the same 42501');

-- ══ c. client_id unique per plant ════════════════════════════════════════
select is((select array_agg(conname::text order by conname) from pg_constraint
            where conrelid = 'public.customer_deliveries'::regclass and contype = 'u'),
  '{customer_deliveries_id_plant_id_key,customer_deliveries_plant_client_id_key}',
  'customer_deliveries: client_id is unique per plant (no global unique)');
select is(pg_temp.val_as('manager', pg_temp.deliver('d2000000-0000-0000-0000-000000000001')), 'false',
  'plant A: a new delivery');
select is(pg_temp.val_as('ownerB', $$select (public.record_customer_delivery(pg_temp.id('plantB'), 'c1000000-0000-0000-0000-0000000000b1',
                                      '[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0b1","bins":1}]',
                                      'd2000000-0000-0000-0000-000000000001', pg_temp.bea())).duplicate$$),
  'false', 'plant B may use the same client_id: its own new delivery (no "already used", nothing about plant A)');
select is(array[(select count(*)::int from public.customer_deliveries where client_id = 'd2000000-0000-0000-0000-000000000001'),
                (select count(distinct plant_id)::int from public.customer_deliveries where client_id = 'd2000000-0000-0000-0000-000000000001')],
  '{2,2}', 'two deliveries, one per plant');
select is(pg_temp.val_as('manager', $$select (public.record_customer_delivery(pg_temp.id('plantA'), 'c1000000-0000-0000-0000-0000000000a1',
                                       '[{"wash_group_id":"71000000-0000-0000-0000-0000000aa0a1","bins":1}]',
                                       'd2000000-0000-0000-0000-000000000001', null)).delivery_id::text$$),
  (select id::text from public.customer_deliveries where client_id = 'd2000000-0000-0000-0000-000000000001' and plant_id = pg_temp.id('plantA')),
  'a retry on plant A still returns plant A''s delivery (no PIN needed)');

-- ══ b. throttle ══════════════════════════════════════════════════════════
-- The manager has 1 delivery on plant A; 9 more reach the limit of 10.
select is((select array_agg(pg_temp.val_as('manager', pg_temp.deliver(('d3000000-0000-0000-0000-00000000000' || i)::uuid)) order by i)
             from generate_series(1, 9) i),
  '{false,false,false,false,false,false,false,false,false}', '10 deliveries by one account in 10 minutes are fine');
select is(pg_temp.val_as('manager', pg_temp.deliver('d3000000-0000-0000-0000-0000000000ff')), 'RATE_LIMITED',
  'the 11th within 10 minutes: RATE_LIMITED');
select is((select count(*)::int from public.customer_deliveries where client_id = 'd3000000-0000-0000-0000-0000000000ff'), 0,
  '… and nothing of it was written');
select is(pg_temp.val_as('manager', pg_temp.deliver('d3000000-0000-0000-0000-000000000003')), 'true',
  'an idempotent retry is not counted: still returns the saved delivery');
select is(pg_temp.val_as('owner', pg_temp.deliver('d3000000-0000-0000-0000-0000000000aa')), 'false',
  'the limit is per account: the owner can still record one');
alter table public.customer_deliveries disable trigger customer_deliveries_guard_update;
update public.customer_deliveries set created_at = created_at - interval '11 minutes' where entered_by = pg_temp.id('manager');
alter table public.customer_deliveries enable trigger customer_deliveries_guard_update;
select is(pg_temp.val_as('manager', pg_temp.deliver('d3000000-0000-0000-0000-0000000000ff')), 'false',
  '10 minutes later the manager can record again');

-- ══ e. estimate batches ══════════════════════════════════════════════════
select ok((select position('pg_advisory_xact_lock' in prosrc) between 1 and position('insert into public.soil_estimates' in prosrc)
             from pg_proc where oid = 'public.record_soil_estimate(uuid, numeric, app.qty_unit, uuid, uuid, text, timestamptz)'::regprocedure),
  'record_soil_estimate takes the batch lock BEFORE its insert');
select is(array[
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 2, 'load', 'e4000000-0000-0000-0000-000000000001', pg_temp.ben())$$),
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gMat'), 1, 'load', 'e4000000-0000-0000-0000-000000000002', pg_temp.ben())$$)],
  '{1,1}', 'a manager enters a batch of 2');
select ok((select bool_and(recorded_at >= now()) and min(recorded_at) < max(recorded_at) from public.soil_estimates
            where client_id in ('e4000000-0000-0000-0000-000000000001', 'e4000000-0000-0000-0000-000000000002')),
  'recorded_at = the wall clock under the lock (grows within one transaction; never before its start)');
-- A first transaction that started long before its estimate got the lock: the alert's sent_at no longer matters.
update public.alert_events set sent_at = now() - interval '1 hour' where kind = 'estimate_entered';
select is((select (app.alert_payload(a) ->> 'count') || ':' || jsonb_array_length(app.alert_payload(a) -> 'estimates')
             from public.alert_events a where a.kind = 'estimate_entered'),
  '2:2', 'the payload window is anchored on the first estimate''s recorded_at, not on the alert''s sent_at');

select * from finish();
rollback;
