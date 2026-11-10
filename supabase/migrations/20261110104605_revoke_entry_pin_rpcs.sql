-- Audit 2026-11-10: the entry-PIN RPCs are no longer client endpoints. Since 2026-11-07 no write needs a
-- staff session (20261107021211: p_staff_session_id is ignored) and no client calls these two RPCs
-- (checked src/ and supabase/functions/ on 2026-11-10). They stay (history rows point at entry_staff /
-- staff_sessions; nothing is dropped) but only the service role may execute them, so a signed-in account
-- can no longer guess entry PINs (start_staff_session) or set them (set_staff_pin) through PostgREST.
revoke execute on function public.start_staff_session(uuid, text) from public, anon, authenticated;
revoke execute on function public.set_staff_pin(uuid, text) from public, anon, authenticated;
grant execute on function public.start_staff_session(uuid, text) to service_role;
grant execute on function public.set_staff_pin(uuid, text) to service_role;

-- Keep each function's documented contract; prefix the new access rule.
do $$
declare
  f regprocedure;
begin
  foreach f in array array['public.start_staff_session(uuid, text)'::regprocedure, 'public.set_staff_pin(uuid, text)'::regprocedure] loop
    execute format('comment on function %s is %L', f,
                   'RETIRED for clients (audit 2026-11-10): service_role only; no client calls it and no write needs an entry PIN since 2026-11-07. Kept for history. '
                   || coalesce(pg_catalog.obj_description(f, 'pg_proc'), ''));
  end loop;
end;
$$;
