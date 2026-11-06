-- Clearing alerts in the Alerts tab (owner 2026-11-06, B). Per person: clearing hides an alert only for
-- the person who cleared it. The 7-day window stays.
--
-- * public.alert_dismissals (alert_id, user_id, dismissed_at): RLS on with no client policies and no
--   client grants (RPC-only), append-only (no update / delete / truncate), org/plant columns with
--   composite FKs. One row per (user, alert). Not audited (personal view state, not operational data);
--   never read by any report and never aggregated by person.
-- * Only alerts the caller actually receives (app.alert_visible_to: the same recipient rules as
--   get_my_alerts) and only when finished can be cleared. A live alert (machine still down, washer still
--   idle, task still open, task done but not yet reviewed by an owner) cannot. route_loaded is
--   informational ("Route 21 loaded"): its still_current only says the route is still marked loaded, so
--   it can always be cleared (otherwise it could never be).
-- * clear_my_alerts(p_plant_id, p_alert_ids[]): clears the listed ids that qualify and silently skips
--   the rest (unknown ids, other people's alerts, other plants', live ones are indistinguishable: no
--   oracle). Returns the ids that are now cleared for the caller.
-- * clear_my_finished_alerts(p_plant_id): clears every qualifying alert of the window. Returns how many
--   were newly cleared.
-- * get_my_alerts gains can_clear; it and get_my_alert_count leave out the caller's cleared alerts.
-- * still_current for task_done is now "done and not yet reviewed" (was always false), so a done task
--   stays live for the owners until one of them reviews it (A); a reviewed task's alerts are finished.

alter table public.alert_events add constraint alert_events_id_plant_key unique (id, plant_id);

create table public.alert_dismissals (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null,
  plant_id     uuid not null,
  alert_id     uuid not null,
  user_id      uuid not null references auth.users(id),
  dismissed_at timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (alert_id, plant_id) references public.alert_events(id, plant_id),
  constraint alert_dismissals_once unique (user_id, alert_id)
);
alter table public.alert_dismissals enable row level security;
create index alert_dismissals_plant_org_idx on public.alert_dismissals (plant_id, org_id);
create index alert_dismissals_alert_plant_idx on public.alert_dismissals (alert_id, plant_id);
comment on table public.alert_dismissals is
  'Owner 2026-11-06 (B): an alert cleared from one person''s Alerts tab (hidden for that person only). RPC-only (clear_my_alerts / clear_my_finished_alerts; RLS on, no client policies or grants), append-only, one row per (user, alert). Never reported or aggregated by person.';
create trigger alert_dismissals_prevent_update before update on public.alert_dismissals for each row execute function app.prevent_mutation();
create trigger alert_dismissals_prevent_delete before delete on public.alert_dismissals for each row execute function app.prevent_mutation();
create trigger alert_dismissals_prevent_truncate before truncate on public.alert_dismissals for each statement execute function app.prevent_delete();
revoke all on public.alert_dismissals from anon, authenticated;

-- ── Is the alert still live? ──────────────────────────────────────────────
create function app.alert_still_current(p_alert public.alert_events, p_payload jsonb)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
  return case p_alert.kind
    when 'machine_down'  then coalesce((p_payload ->> 'still_down')::boolean, false)
    when 'washer_idle'   then coalesce((p_payload ->> 'still_idle')::boolean, false)
    when 'task_assigned' then p_payload ? 'task_id' and (p_payload ->> 'done_at') is null
    when 'task_done'     then p_payload ? 'task_id' and (p_payload ->> 'done_at') is not null and (p_payload ->> 'reviewed_at') is null
    when 'route_loaded'  then coalesce((
      select e2.loaded from public.route_load_events e
        join public.route_load_events e2 on e2.route_id = e.route_id and e2.plant_id = e.plant_id and e2.load_date = e.load_date
       where e.id = p_alert.subject_id and e.plant_id = p_alert.plant_id
       order by e2.occurred_at desc, e2.seq desc limit 1), false)
    else false end;
end;
$$;
comment on function app.alert_still_current(public.alert_events, jsonb) is
  'Alerts tab (2026-11-06): the alert''s state, from its app.alert_payload: machine still down / washer still idle / task still open (task_assigned) / task done but not yet reviewed (task_done) / route still marked loaded. Internal.';
revoke all on function app.alert_still_current(public.alert_events, jsonb) from public, anon, authenticated;

create function app.alert_can_clear(p_alert public.alert_events, p_payload jsonb)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_alert.kind = 'route_loaded' or not app.alert_still_current(p_alert, p_payload);
$$;
comment on function app.alert_can_clear(public.alert_events, jsonb) is
  'Alerts tab (2026-11-06, B): an alert can be cleared when it is no longer live (route_loaded is informational and always clearable). Internal.';
revoke all on function app.alert_can_clear(public.alert_events, jsonb) from public, anon, authenticated;

-- ── get_my_alerts: + can_clear, without the caller's cleared alerts ───────
drop function public.get_my_alerts(uuid, int);
create function public.get_my_alerts(p_plant_id uuid, p_limit int default 50)
returns table (alert_id uuid, kind text, created_at timestamptz, payload jsonb, still_current boolean, can_clear boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_plant uuid;
  v_me    uuid := (select auth.uid());
begin
  select p.id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant is null or not app.has_role(v_plant, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_my_alerts requires owner or manager on the plant';
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'VALIDATION_FAILED' using detail = 'p_limit: 1–200';
  end if;
  return query
  select a.id, a.kind, a.sent_at, x.payload, s.cur, a.kind = 'route_loaded' or not s.cur
    from public.alert_events a
   cross join lateral (select app.alert_payload(a) as payload) x
   cross join lateral (select app.alert_still_current(a, x.payload) as cur) s
   where a.plant_id = v_plant
     and a.kind = any (app.push_alert_kinds())
     and a.sent_at > pg_catalog.now() - interval '7 days'
     and app.alert_visible_to(a, v_me)
     and not exists (select 1 from public.alert_dismissals d where d.user_id = v_me and d.alert_id = a.id)
   order by a.sent_at desc, a.id desc
   limit p_limit;
end;
$$;
comment on function public.get_my_alerts(uuid, int) is
  'Alerts tab (2026-11-06; owner/manager of the plant; definer, role check first): the push alerts of the last 7 days that the caller would receive (same rules as the push; task_assigned once per task) and has not cleared, newest first, at most p_limit (1–200, default 50). Columns: alert_id, kind, created_at, payload (app.alert_payload: no free text except a task''s text for its recipients, no names), still_current (still down / still idle / task open / task done and awaiting review / route still loaded), can_clear (not still_current, or route_loaded). Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.get_my_alerts(uuid, int) from public, anon;
grant execute on function public.get_my_alerts(uuid, int) to authenticated, service_role;

create or replace function public.get_my_alert_count(p_plant_id uuid, p_since timestamptz default null)
returns int language plpgsql stable security definer set search_path = '' as $$
declare
  v_plant uuid;
  v_from  timestamptz;
  v_me    uuid := (select auth.uid());
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
     and app.alert_visible_to(a, v_me)
     and not exists (select 1 from public.alert_dismissals d where d.user_id = v_me and d.alert_id = a.id);
  return v_n;
end;
$$;
comment on function public.get_my_alert_count(uuid, timestamptz) is
  'Alerts tab badge (2026-11-06; owner/manager; definer, role check first): how many of the caller''s alerts (same rules as get_my_alerts, cleared ones left out) were written after greatest(p_since, now − 7 days), or in the last 24 hours when p_since is null. Errors: NOT_AUTHORIZED.';

-- ── clear_my_alerts ───────────────────────────────────────────────────────
create function public.clear_my_alerts(p_plant_id uuid, p_alert_ids uuid[])
returns table (alert_id uuid) language plpgsql volatile security definer set search_path = '' as $$
declare
  v_plant record;
  v_me    uuid := (select auth.uid());
  v_ids   uuid[];
begin
  select p.id, p.org_id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant.id is null or not app.has_role(v_plant.id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'clear_my_alerts requires owner or manager on the plant';
  end if;
  if p_alert_ids is null or pg_catalog.cardinality(p_alert_ids) not between 1 and 200
     or pg_catalog.array_position(p_alert_ids, null) is not null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_alert_ids: 1–200 ids, no nulls';
  end if;
  -- The caller's own, finished alerts of the window; everything else is skipped without a trace.
  select coalesce(pg_catalog.array_agg(a.id), '{}') into v_ids
    from public.alert_events a
   where a.id = any (p_alert_ids)
     and a.plant_id = v_plant.id
     and a.kind = any (app.push_alert_kinds())
     and a.sent_at > pg_catalog.now() - interval '7 days'
     and app.alert_visible_to(a, v_me)
     and app.alert_can_clear(a, app.alert_payload(a));
  insert into public.alert_dismissals (org_id, plant_id, alert_id, user_id)
  select v_plant.org_id, v_plant.id, x, v_me from pg_catalog.unnest(v_ids) x
  on conflict on constraint alert_dismissals_once do nothing;
  return query select x from pg_catalog.unnest(v_ids) x;
end;
$$;
comment on function public.clear_my_alerts(uuid, uuid[]) is
  'Owner 2026-11-06 RPC (owner/manager of the plant; definer, role check first): clears up to 200 alerts from the CALLER''s Alerts tab only. An id is cleared only when it is one of the caller''s alerts of the last 7 days (get_my_alerts rules) and can_clear (no longer live: machine fixed, washer started, task done/reviewed; route_loaded always). Other ids (unknown, someone else''s, another plant''s, live) are skipped silently. Idempotent. Returns the ids now cleared for the caller. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.clear_my_alerts(uuid, uuid[]) from public, anon;
grant execute on function public.clear_my_alerts(uuid, uuid[]) to authenticated, service_role;

-- ── clear_my_finished_alerts ──────────────────────────────────────────────
create function public.clear_my_finished_alerts(p_plant_id uuid)
returns int language plpgsql volatile security definer set search_path = '' as $$
declare
  v_plant record;
  v_me    uuid := (select auth.uid());
  v_n     int;
begin
  select p.id, p.org_id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant.id is null or not app.has_role(v_plant.id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'clear_my_finished_alerts requires owner or manager on the plant';
  end if;
  insert into public.alert_dismissals (org_id, plant_id, alert_id, user_id)
  select v_plant.org_id, v_plant.id, a.id, v_me
    from public.alert_events a
   where a.plant_id = v_plant.id
     and a.kind = any (app.push_alert_kinds())
     and a.sent_at > pg_catalog.now() - interval '7 days'
     and app.alert_visible_to(a, v_me)
     and not exists (select 1 from public.alert_dismissals d where d.user_id = v_me and d.alert_id = a.id)
     and app.alert_can_clear(a, app.alert_payload(a))
  on conflict on constraint alert_dismissals_once do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
comment on function public.clear_my_finished_alerts(uuid) is
  'Owner 2026-11-06 RPC (owner/manager of the plant; definer, role check first): "clear all finished": clears every alert of the last 7 days in the CALLER''s Alerts tab that can_clear (live alerts stay). Only the caller''s view changes. Returns how many were newly cleared. Errors: NOT_AUTHORIZED.';
revoke all on function public.clear_my_finished_alerts(uuid) from public, anon;
grant execute on function public.clear_my_finished_alerts(uuid) to authenticated, service_role;
