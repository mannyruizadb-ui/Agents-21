-- Alerts tab badge (2026-11-06): get_my_alert_count gains p_since ("unseen since I last opened the
-- tab"). With p_since: alerts created after greatest(p_since, now − 7 days) (the tab's own window);
-- without it: the last 24 hours, as before. Replaced compatibly: calls with only p_plant_id keep working.

drop function public.get_my_alert_count(uuid);
create function public.get_my_alert_count(p_plant_id uuid, p_since timestamptz default null)
returns int language plpgsql stable security definer set search_path = '' as $$
declare
  v_plant uuid;
  v_from  timestamptz;
  v_n     int;
begin
  select p.id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant is null or not app.has_role(v_plant, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_my_alert_count requires owner or manager on the plant';
  end if;
  v_from := case when p_since is null then pg_catalog.now() - interval '24 hours'
                 else greatest(p_since, pg_catalog.now() - interval '7 days') end;
  select count(*)::int into v_n
    from public.alert_events a
   where a.plant_id = v_plant
     and a.kind = any (app.push_alert_kinds())
     and a.sent_at > v_from
     and app.alert_visible_to(a, (select auth.uid()));
  return v_n;
end;
$$;
comment on function public.get_my_alert_count(uuid, timestamptz) is
  'Alerts tab badge (2026-11-06; owner/manager; definer, role check first): how many of the caller''s alerts (same rules as get_my_alerts) were written after greatest(p_since, now − 7 days), or in the last 24 hours when p_since is null. Errors: NOT_AUTHORIZED.';
revoke all on function public.get_my_alert_count(uuid, timestamptz) from public, anon;
grant execute on function public.get_my_alert_count(uuid, timestamptz) to authenticated, service_role;
