-- Schema-wide guards for the M1 foundation (PRD §4.4 tables, §4.8 indexes, §5.3 RPC hygiene).
begin;
select plan(11);

select is(
  (select count(*)::int from pg_tables where schemaname = 'public'),
  26, '§4.4: 26 tables in public');

-- Every FK has a non-partial index whose leading columns are exactly the FK columns (§4.8).
select is(
  (select coalesce(array_agg(c.conrelid::regclass::text || ':' || c.conname order by 1), '{}')
     from pg_constraint c
     join pg_namespace n on n.oid = c.connamespace
    where c.contype = 'f' and n.nspname = 'public'
      and not exists (
        select 1 from pg_index i
         where i.indrelid = c.conrelid and i.indpred is null
           and (select array_agg(k order by k) from unnest((i.indkey::int2[])[0:cardinality(c.conkey) - 1]) k)
             = (select array_agg(k order by k) from unnest(c.conkey) k))),
  '{}'::text[], '§4.8: every foreign key is covered by an index');

-- Only global/tenancy tables lack plant_id.
select is(
  (select array_agg(t.tablename::text order by t.tablename) from pg_tables t
    where t.schemaname = 'public'
      and not exists (select 1 from information_schema.columns c
                       where c.table_schema = 'public' and c.table_name = t.tablename and c.column_name = 'plant_id')),
  array['languages','organizations','plants','profiles'], 'every operational table has plant_id');

select is(
  (select array_agg(tablename::text order by tablename) from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public'),
  array['display_messages','queue_items','soil_estimates'], 'Realtime publishes only queue_items, soil_estimates, display_messages');

select enum_has_labels('app', 'qty_unit', array['load','basket','piece','pack'], 'qty_unit has no weight units');

select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}') from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'app') and obj_description(p.oid, 'pg_proc') is null),
  '{}'::text[], 'every function in public/app has a comment');

select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}') from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')),
  '{}'::text[], 'anon cannot execute any public RPC');

select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}') from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f' and not p.prosecdef),
  '{}'::text[], 'every public RPC is SECURITY DEFINER');

select is(
  array[has_function_privilege('authenticated', 'app.generate_shift_instances(uuid,int,date)', 'execute'),
        has_function_privilege('authenticated', 'app.resolve_entry_shift(uuid,text,timestamptz,uuid)', 'execute'),
        has_function_privilege('authenticated', 'app.shift_instance_at(uuid,timestamptz)', 'execute')],
  array[false, false, false], 'shift generation/resolution helpers are not client-callable');

select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}') from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and has_function_privilege('public', p.oid, 'execute')),
  '{}'::text[], 'no app function is executable by PUBLIC (grants are per function)');

select ok(has_function_privilege('service_role', 'app.generate_shift_instances(uuid,int,date)', 'execute'),
  'service_role may run app.generate_shift_instances (pg_cron / Edge Functions)');

select * from finish();
rollback;
