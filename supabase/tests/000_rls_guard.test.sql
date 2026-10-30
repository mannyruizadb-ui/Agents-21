-- Guard tests that protect every future migration (CLAUDE.md: "RLS is enabled on every
-- table, deny-by-default"). Exposed schema: public (supabase/config.toml [api].schemas).
begin;
select plan(5);

-- 1. Every table (incl. partitions) in public has RLS enabled.
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

-- 2. Views run with the caller's rights, so table RLS still applies (security_invoker).
select is(
  (select coalesce(array_agg(c.relname::text order by c.relname), '{}')
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'v'
      and not coalesce(c.reloptions @> array['security_invoker=true'], false)),
  '{}'::text[],
  'all public views use security_invoker'
);

-- 3. No materialized views or foreign tables in public: they cannot have RLS.
select is(
  (select coalesce(array_agg(c.relname::text order by c.relname), '{}')
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('m', 'f')),
  '{}'::text[],
  'no materialized views or foreign tables in public'
);

-- 4. SECURITY DEFINER functions in public or app pin search_path to '' (.claude/rules/database.md).
select is(
  (select coalesce(array_agg(n.nspname || '.' || p.proname order by n.nspname, p.proname), '{}')
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'app')
      and p.prosecdef
      and not coalesce(p.proconfig @> array['search_path=""'], false)),
  '{}'::text[],
  'security definer functions set search_path to empty'
);

select has_schema('app', 'helper schema app exists');

select * from finish();
rollback;
