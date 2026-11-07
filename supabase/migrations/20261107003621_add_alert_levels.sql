-- Alert levels (owner 2026-11-06, C): alerts for nearly everything, at two levels to avoid alarm fatigue.
--
-- New OWNER alert kinds (informational: still_current = false, always clearable; payloads carry no
-- person names; the producers are in 20261107003623 / 20261107003625, the payloads in 20261107003625):
--   customer_delivery  an outside customer's goods were delivered (record_customer_delivery)
--   estimate_entered   soil estimates were entered (one alert per entry batch)
--   rewash_added       a manager added a rewash item to the queue
--   off_queue_start    a washer start whose group is not what the queue had next for that washer, or an
--                      off-queue load
--
-- Per-owner level per kind: push (push + Alerts tab + badge) | quiet (Alerts tab + badge, no push) | off
-- (hidden). Stored as memberships.alert_levels (jsonb map kind → level, CHECKed) rather than a new table:
--   * same place and pattern as the existing per-membership alert switches (notify_machine_down,
--     notify_washer_idle), read with the membership in one query, no extra RLS surface;
--   * the set of kinds is small and closed (CHECK lists them); a missing key means the kind's default
--     (app.alert_level_default), so adding a kind later needs no backfill.
-- Defaults: customer_delivery = push; estimate_entered, rewash_added, off_queue_start = quiet.
-- Existing kinds keep their own switches (notify_machine_down / notify_washer_idle); levels apply only to
-- the four kinds above. An owner with several owner memberships of the plant (plant + org-wide) gets the
-- strongest level among them (push > quiet > off), like notify_washer_idle (any membership with it on).
-- Only owner memberships are read: managers never receive these kinds.
-- Writes: the app uses set_alert_level (it checks that the target is an owner membership). memberships
-- keeps its existing table-level UPDATE grant, so an owner could also write the column directly (RLS:
-- owners only); the CHECK keeps any such value valid.
--
-- Delivery: the new kinds join app.push_alert_kinds() (the kinds the Alerts tab and the push pipeline
-- look at). A push recipient is an owner whose level is push. An alert that has no push recipient when it
-- is written is stored with recipients '{quiet}' (delivered: nothing to send), so switching a kind to push
-- later never pushes old alerts. send-alerts marks kinds it has no builder for as 'none' (never sent).

alter table public.alert_events
  drop constraint alert_events_kind_check,
  add constraint alert_events_kind_check check (kind in ('estimate_stale', 'device_offline', 'import_failed',
    'shift_generation_failed', 'machine_down', 'washer_idle', 'task_assigned', 'task_done', 'route_loaded',
    'customer_delivery', 'estimate_entered', 'rewash_added', 'off_queue_start'));
comment on table public.alert_events is
  'Alerts for the notifier (service role only; RLS on, no client policies). Push kinds: machine_down (subject = machine_status_events.id), washer_idle (subject = machine, dedupe_key = finished cycle), task_assigned (subject = task, dedupe_key = reminder number), task_done (subject = task), route_loaded (subject = route_load_events.id); owner info kinds (2026-11-06, levels per owner): customer_delivery (subject = customer_deliveries.id), estimate_entered (subject = the first soil_estimates.id of the batch), rewash_added (subject = queue_items.id), off_queue_start (subject = washer_cycles.id, dedupe_key = the wash group the queue had next for that washer, null = nothing queued). recipients ''{}'' = not yet delivered; ''{claimed}'' = being delivered; ''{quiet}'' = no push recipient when written. One row per (kind, subject, shift, dedupe_key).';

-- ── Kinds, levels, defaults ───────────────────────────────────────────────
create function app.owner_alert_kinds()
returns text[] language sql immutable set search_path = '' as $$
  select array['customer_delivery', 'estimate_entered', 'rewash_added', 'off_queue_start'];
$$;
comment on function app.owner_alert_kinds() is
  'Owner 2026-11-06 (C): the owner information alert kinds that have a per-owner level (push | quiet | off).';
revoke all on function app.owner_alert_kinds() from public, anon, authenticated;

create function app.alert_level_default(p_kind text)
returns text language sql immutable set search_path = '' as $$
  select case p_kind when 'customer_delivery' then 'push'
                     when 'estimate_entered' then 'quiet'
                     when 'rewash_added' then 'quiet'
                     when 'off_queue_start' then 'quiet' end;
$$;
comment on function app.alert_level_default(text) is
  'Owner 2026-11-06 (C): default level per owner alert kind: customer_delivery push; estimate_entered, rewash_added, off_queue_start quiet; null for other kinds.';
revoke all on function app.alert_level_default(text) from public, anon, authenticated;

alter table public.memberships
  add column alert_levels jsonb not null
    default '{"customer_delivery":"push","estimate_entered":"quiet","rewash_added":"quiet","off_queue_start":"quiet"}'::jsonb,
  -- Inline (no function call): a CHECK runs with the writer's privileges, and memberships is written by
  -- owners directly. Keys: the owner alert kinds; values: "push" | "quiet" | "off".
  add constraint memberships_alert_levels_ok check (
    jsonb_typeof(alert_levels) = 'object'
    and (alert_levels - '{customer_delivery,estimate_entered,rewash_added,off_queue_start}'::text[]) = '{}'::jsonb
    and not jsonb_path_exists(alert_levels, '$.* ? (@.type() != "string" || (@ != "push" && @ != "quiet" && @ != "off"))'));
comment on column public.memberships.alert_levels is
  'Owner 2026-11-06 (C): for OWNER memberships, the level of each owner information alert kind: push (push + Alerts tab) | quiet (Alerts tab and badge only) | off (hidden). A missing kind = its default (app.alert_level_default). Ignored for other roles. Set via set_alert_level (owners only; the CHECK guards any direct owner write).';
grant select (alert_levels) on public.memberships to authenticated;

-- The caller's effective level for a kind on a plant: the strongest among their active OWNER memberships
-- of the plant (plant or org-wide); null when they are not an owner of it.
create function app.owner_alert_level(p_plant_id uuid, p_user uuid, p_kind text)
returns text language sql stable security definer set search_path = '' as $$
  select case max(case coalesce(m.alert_levels ->> p_kind, app.alert_level_default(p_kind))
                    when 'push' then 3 when 'quiet' then 2 when 'off' then 1 end)
           when 3 then 'push' when 2 then 'quiet' when 1 then 'off' end
    from public.memberships m
    join public.plants p on p.id = p_plant_id and p.org_id = m.org_id
   where m.user_id = p_user and m.role = 'owner' and m.revoked_at is null
     and (m.plant_id is null or m.plant_id = p_plant_id);
$$;
comment on function app.owner_alert_level(uuid, uuid, text) is
  'Owner 2026-11-06 (C): a user''s level for an owner alert kind on a plant: the strongest (push > quiet > off) among their active owner memberships of the plant or its org; null when not an owner. Internal.';
revoke all on function app.owner_alert_level(uuid, uuid, text) from public, anon, authenticated;
grant execute on function app.owner_alert_level(uuid, uuid, text) to service_role;

-- Owners of a plant whose level for p_kind is one of p_levels.
create function app.plant_owner_alert_users(p_plant_id uuid, p_kind text, p_levels text[])
returns setof uuid language sql stable security definer set search_path = '' as $$
  select u from app.plant_owner_users(p_plant_id) u
   where app.owner_alert_level(p_plant_id, u, p_kind) = any (p_levels);
$$;
comment on function app.plant_owner_alert_users(uuid, text, text[]) is
  'Owner 2026-11-06 (C): user ids of the plant''s owners whose level for p_kind is in p_levels. Internal.';
revoke all on function app.plant_owner_alert_users(uuid, text, text[]) from public, anon, authenticated;
grant execute on function app.plant_owner_alert_users(uuid, text, text[]) to service_role;

-- Writes one owner information alert (idempotent on the alert key). recipients '{}' when some owner wants
-- it pushed, else '{quiet}' (nothing to send, ever). Returns the alert id, or null when it already existed.
create function app.raise_owner_alert(p_org_id uuid, p_plant_id uuid, p_kind text, p_subject_id uuid,
                                      p_dedupe_key text default null)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  if not (p_kind = any (app.owner_alert_kinds())) then
    raise exception 'VALIDATION_FAILED' using detail = 'kind: not an owner alert kind';
  end if;
  insert into public.alert_events as a (org_id, plant_id, kind, subject_id, recipients, dedupe_key)
  values (p_org_id, p_plant_id, p_kind, p_subject_id,
          case when exists (select 1 from app.plant_owner_alert_users(p_plant_id, p_kind, '{push}'))
               then '{}'::text[] else '{quiet}'::text[] end,
          p_dedupe_key)
  on conflict (kind, subject_id, shift_instance_id, dedupe_key) do nothing
  returning a.id into v_id;
  return v_id;
end;
$$;
comment on function app.raise_owner_alert(uuid, uuid, text, uuid, text) is
  'Owner 2026-11-06 (C): writes an owner information alert (kind in app.owner_alert_kinds()). recipients ''{}'' (pending push) when at least one owner of the plant has the kind at push, else ''{quiet}''. Idempotent on (kind, subject, shift, dedupe_key). Returns the new alert id or null. Internal (called by RPCs after their own role checks).';
revoke all on function app.raise_owner_alert(uuid, uuid, text, uuid, text) from public, anon, authenticated;
grant execute on function app.raise_owner_alert(uuid, uuid, text, uuid, text) to service_role;

-- ── The Alerts tab / push pipeline look at the new kinds too ──────────────
create or replace function app.push_alert_kinds()
returns text[] language sql immutable set search_path = '' as $$
  select array['machine_down', 'washer_idle', 'task_assigned', 'task_done', 'route_loaded',
               'customer_delivery', 'estimate_entered', 'rewash_added', 'off_queue_start'];
$$;
comment on function app.push_alert_kinds() is
  'Owner 2026-11-06: alert_events kinds shown in the Alerts tab and delivered by Web Push to their push recipients (owner information kinds only to owners whose level is push).';

create or replace function app.alert_recipient_users(p_alert public.alert_events)
returns setof uuid language plpgsql stable security definer set search_path = '' as $$
begin
  if p_alert.kind = 'machine_down' then
    return query
      select distinct m.user_id from public.memberships m
        join public.plants p on p.id = p_alert.plant_id and p.org_id = m.org_id
       where m.revoked_at is null and m.role in ('owner', 'manager') and m.notify_machine_down
         and (m.plant_id is null or m.plant_id = p_alert.plant_id);
  elsif p_alert.kind = 'washer_idle' then
    -- Owners who kept it on, plus the managers on duty when it fired (always: owner-approved safeguard).
    return query
      select u from app.plant_idle_alert_owners(p_alert.plant_id) u
      union
      select u from app.managers_on_duty(p_alert.plant_id, p_alert.sent_at) u;
  elsif p_alert.kind = 'route_loaded' then
    return query select u from app.plant_owner_users(p_alert.plant_id) u;
  elsif p_alert.kind = 'task_assigned' then
    -- Only while the task is open, and only its assignees (the task text is for them).
    return query
      select x from public.tasks t cross join lateral pg_catalog.unnest(t.assignee_user_ids) x
       where t.id = p_alert.subject_id and t.plant_id = p_alert.plant_id and t.done_at is null;
  elsif p_alert.kind = 'task_done' then
    return query select u from app.plant_owner_users(p_alert.plant_id) u;
  elsif p_alert.kind = any (app.owner_alert_kinds()) then
    -- Owner information kinds: pushed only to owners whose level is push (quiet = Alerts tab only).
    return query select u from app.plant_owner_alert_users(p_alert.plant_id, p_alert.kind, '{push}') u;
  end if;
end;
$$;
comment on function app.alert_recipient_users(public.alert_events) is
  'Owner 2026-11-06: who receives a push alert. machine_down: owner/manager members with notify_machine_down; washer_idle: the plant''s owners with notify_washer_idle + the managers on duty when it fired (always); route_loaded / task_done: the plant''s owners; task_assigned: the task''s assignees while it is open; customer_delivery / estimate_entered / rewash_added / off_queue_start: the plant''s owners whose level for the kind is push. Internal.';

create or replace function app.alert_visible_to(p_alert public.alert_events, p_user uuid)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
  if p_user is null then
    return false;
  end if;
  -- Every reader is an active owner or manager of the alert's plant.
  if not exists (select 1 from public.memberships m
                  join public.plants p on p.id = p_alert.plant_id and p.org_id = m.org_id
                  where m.user_id = p_user and m.revoked_at is null and m.role in ('owner', 'manager')
                    and (m.plant_id is null or m.plant_id = p_alert.plant_id)) then
    return false;
  end if;
  if p_alert.kind = 'machine_down' then
    return exists (select 1 from public.memberships m
                    join public.plants p on p.id = p_alert.plant_id and p.org_id = m.org_id
                    where m.user_id = p_user and m.revoked_at is null and m.role in ('owner', 'manager')
                      and m.notify_machine_down and (m.plant_id is null or m.plant_id = p_alert.plant_id));
  elsif p_alert.kind = 'washer_idle' then
    return exists (select 1 from app.plant_idle_alert_owners(p_alert.plant_id) u where u = p_user)
        or exists (select 1 from app.managers_on_duty(p_alert.plant_id, p_alert.sent_at) u where u = p_user);
  elsif p_alert.kind = 'task_assigned' then
    return coalesce(p_alert.dedupe_key, '0') = '0'
       and exists (select 1 from public.tasks t
                    where t.id = p_alert.subject_id and t.plant_id = p_alert.plant_id and p_user = any (t.assignee_user_ids));
  elsif p_alert.kind in ('task_done', 'route_loaded') then
    return exists (select 1 from app.plant_owner_users(p_alert.plant_id) u where u = p_user);
  elsif p_alert.kind = any (app.owner_alert_kinds()) then
    -- Owners only; push and quiet show in the Alerts tab, off hides the kind.
    return coalesce(app.owner_alert_level(p_alert.plant_id, p_user, p_alert.kind) in ('push', 'quiet'), false);
  end if;
  return false;
end;
$$;
comment on function app.alert_visible_to(public.alert_events, uuid) is
  'Alerts tab (2026-11-06): true when p_user would see this alert: the push recipient rules applied to history (washer_idle to owners with notify_washer_idle and the managers on duty when it fired; task_assigned listed once per task, for its assignees even after done), and for the owner information kinds (customer_delivery, estimate_entered, rewash_added, off_queue_start) the plant''s owners whose level is push or quiet (off hides them). Internal.';

-- ── set_alert_level ───────────────────────────────────────────────────────
create function public.set_alert_level(p_membership_id uuid, p_kind text, p_level text)
returns public.memberships language plpgsql volatile security definer set search_path = '' as $$
declare
  v public.memberships;
begin
  -- Role check FIRST: the caller must be an owner of the membership's plant (or of its org for an
  -- org-wide membership). Missing and foreign ids give the same NOT_AUTHORIZED.
  select m.* into v from public.memberships m where m.id = p_membership_id;
  if v.id is null
     or not (case when v.plant_id is null then app.has_org_role(v.org_id, '{owner}')
                  else app.has_role(v.plant_id, '{owner}') end) then
    raise exception 'NOT_AUTHORIZED' using detail = 'set_alert_level requires owner of the membership''s plant';
  end if;
  if p_kind is null or not (p_kind = any (app.owner_alert_kinds())) then
    raise exception 'VALIDATION_FAILED' using detail = 'p_kind: customer_delivery, estimate_entered, rewash_added or off_queue_start';
  end if;
  if p_level is null or p_level not in ('push', 'quiet', 'off') then
    raise exception 'VALIDATION_FAILED' using detail = 'p_level: push, quiet or off';
  end if;
  if v.revoked_at is not null then
    raise exception 'VALIDATION_FAILED' using detail = 'membership: revoked';
  end if;
  if v.role <> 'owner' then
    raise exception 'VALIDATION_FAILED' using detail = 'only owner memberships have alert levels';
  end if;
  update public.memberships m
     set alert_levels = m.alert_levels || pg_catalog.jsonb_build_object(p_kind, p_level)
   where m.id = v.id
  returning m.* into v;
  return v;
end;
$$;
comment on function public.set_alert_level(uuid, text, text) is
  'Owner 2026-11-06 RPC (owner of the membership''s plant, or of the org for an org-wide membership; definer, role check first, no oracle): sets one OWNER membership''s level for an owner information alert kind (customer_delivery | estimate_entered | rewash_added | off_queue_start) to push (push + Alerts tab), quiet (Alerts tab and badge, no push) or off (hidden). Same targeting rule as set_washer_idle_alert. Returns the memberships row (alert_levels). Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.set_alert_level(uuid, text, text) from public, anon;
grant execute on function public.set_alert_level(uuid, text, text) to authenticated, service_role;
