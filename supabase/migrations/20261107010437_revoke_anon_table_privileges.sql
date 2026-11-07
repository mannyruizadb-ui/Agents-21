-- Security carry-forward L3 (M2 review, re-raised in the 312ca2e review): the anon role keeps no
-- privileges on any table, view or sequence in schema public, now or in the future.
--
-- Why: anon had Supabase's default table grants. RLS denied it every row, but a BEFORE INSERT
-- validation trigger runs before the RLS WITH CHECK, so an anon insert probe on e.g. wash_groups with
-- a real plant id answered VALIDATION_FAILED (the plant exists) instead of 42501. With no table
-- privilege, the privilege check comes first and every anon probe is 42501.
--
-- Checked before revoking (2026-11-07): nothing reads or writes tables as anon.
--   * src/: every .from()/.rpc() call sits under /control or /station behind RequireAuth; the sign-in
--     page uses Supabase Auth only; /display and /pair are placeholders (displays will use
--     authenticated device sessions).
--   * supabase/functions: manage-users uses the caller's JWT (authenticated) and the service role;
--     send-alerts and sign-in use the service role only. pg_cron jobs run as postgres.
--   * anon already executes no public RPC (001_schema_guards) and has no USAGE on schema app.
--
-- Default privileges: migrations create objects as postgres, so the defaults for role postgres are
-- the ones that apply to future tables (supabase_admin's defaults cover only objects that
-- supabase_admin itself creates, which migrations never do, and postgres cannot change them).

do $$
declare
  r record;
begin
  for r in
    select c.oid::regclass as rel
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'f', 'S')
  loop
    execute format('revoke all on %s from anon', r.rel);
  end loop;
end;
$$;

alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;
alter default privileges for role postgres in schema public revoke all on functions from anon;
