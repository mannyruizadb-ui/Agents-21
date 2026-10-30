-- Guard: every table in `public` must have row level security enabled (CLAUDE.md:
-- "RLS is enabled on every table, deny-by-default"). Runs against every future migration.
begin;
select plan(2);

select is(
  (select coalesce(array_agg(c.relname::text order by c.relname), '{}')
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p')
      and not c.relrowsecurity),
  '{}'::text[],
  'all public tables have RLS enabled'
);

select has_schema('app', 'helper schema app exists');

select * from finish();
rollback;
