-- Machine down / back up (owner 2026-11-04, round 2): any machine (washer, dryer, ironer, folder, …)
-- can be marked DOWN with a short reason and later back UP. Shown on the owner boards; a down washer
-- refuses start-taps (next migration). Push notifications (owner approved free Web Push, not SMS)
-- hook on alert_events: marking a machine down writes one alert_events row (kind machine_down).
--
-- Append-only history (no updates, no deletes): the current status of a machine is its latest event
-- (occurred_at desc, seq desc). No event = up. Writes only through set_machine_status (owner/manager;
-- definer, role check before any lookup, plant-filtered, client_id idempotency). Reads: table RLS
-- (owner/manager/lead/viewer of the plant), get_machine_status (all machines of a plant) and
-- get_washroom_board (washers; also for the area's display).
--
-- Push hook point (for the future Web Push Edge Function, not built here):
--   alert_events where kind = 'machine_down' and recipients = '{}' are not yet delivered.
--   subject_id = machine_status_events.id (join it for machine, reason, occurred_at). The sender fills
--   recipients (push subscription ids or user ids) when it has delivered, so a retry never sends twice.
--   alert_events' unique (kind, subject_id, shift_instance_id) gives exactly one alert per down event.

create type app.machine_status as enum ('down', 'up');
comment on type app.machine_status is 'Machine availability (owner 2026-11-04): down = broken / out of service; up = working.';

create table public.machine_status_events (
  id          uuid primary key default gen_random_uuid(),
  seq         bigint generated always as identity,          -- tie-break for events in one transaction
  org_id      uuid not null,
  plant_id    uuid not null,
  machine_id  uuid not null,
  status      app.machine_status not null,
  reason      text check (char_length(reason) between 1 and 200 and app.is_clean_text(reason)),
  occurred_at timestamptz not null default now(),
  entered_by  uuid references auth.users(id),               -- the signed-in account; null = service role
  client_id   uuid not null unique,
  created_at  timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (machine_id, plant_id) references public.machines(id, plant_id),
  constraint machine_status_events_down_needs_reason check (status <> 'down' or reason is not null)
);
alter table public.machine_status_events enable row level security;
create index machine_status_events_plant_org_idx on public.machine_status_events (plant_id, org_id);
create index machine_status_events_current_idx
  on public.machine_status_events (machine_id, plant_id, occurred_at desc, seq desc);
create index machine_status_events_entered_by_idx on public.machine_status_events (entered_by);
comment on table public.machine_status_events is
  'Owner 2026-11-04: append-only machine down/up history. Current status = latest event per machine (occurred_at desc, seq desc); no event = up. Down needs a reason (≤ 200). Client writes only through set_machine_status (owner/manager). A down event writes alert_events kind machine_down (push hook).';
comment on column public.machine_status_events.reason is
  'Why the machine is down (required for down, optional for up), 1–200 characters, no control characters.';

create trigger machine_status_events_prevent_mutation before update or delete on public.machine_status_events
  for each row execute function app.prevent_mutation();
create trigger machine_status_events_prevent_truncate before truncate on public.machine_status_events
  for each statement execute function app.prevent_delete();
create trigger machine_status_events_audit after insert on public.machine_status_events
  for each row execute function app.audit();

-- Reads: every signed-in role of the plant (machine availability is not per-person data; entered_by is
-- not exposed by the read RPCs). Displays read washer status through get_washroom_board.
create policy machine_status_events_select on public.machine_status_events for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')));
-- anon gets nothing (security follow-up L3 for new tables); clients only read.
revoke all on public.machine_status_events from anon;
revoke insert, update, delete, truncate, references, trigger on public.machine_status_events from authenticated;

-- ── alert_events: + machine_down ──────────────────────────────────────────
-- Widens the CHECK only (no data changes). subject_id = the machine_status_events id.
alter table public.alert_events drop constraint alert_events_kind_check;
alter table public.alert_events add constraint alert_events_kind_check
  check (kind in ('estimate_stale','device_offline','import_failed','shift_generation_failed','machine_down'));
comment on table public.alert_events is
  'Alerts for the notifier (service role only; RLS on, no client policies). Kinds: estimate_stale, device_offline, import_failed, shift_generation_failed (subject = plant), machine_down (owner 2026-11-04; subject = machine_status_events.id; recipients ''{}'' = not yet delivered, the Web Push sender fills it). One row per (kind, subject, shift).';

-- ── Internal helper: is the machine down at p_ts? ─────────────────────────
create function app.machine_is_down_at(p_machine_id uuid, p_plant_id uuid, p_ts timestamptz)
returns boolean language sql stable set search_path = '' as $$
  select coalesce((
    select e.status = 'down'
      from public.machine_status_events e
     where e.machine_id = p_machine_id and e.plant_id = p_plant_id and e.occurred_at <= p_ts
     order by e.occurred_at desc, e.seq desc
     limit 1), false);
$$;
comment on function app.machine_is_down_at(uuid, uuid, timestamptz) is
  'Owner 2026-11-04: true when the latest machine_status_events row of the machine (in p_plant_id) at or before p_ts is down; no event = up (false). Internal (definer RPCs only).';
revoke all on function app.machine_is_down_at(uuid, uuid, timestamptz) from public, anon, authenticated;

-- ── set_machine_status ────────────────────────────────────────────────────
create type public.machine_status_result as (
  event_id    uuid,
  machine_id  uuid,
  status      app.machine_status,
  reason      text,
  since       timestamptz,       -- occurred_at of the event now in force
  changed     boolean            -- false = already in this status, or a retry of a recorded client_id
);
comment on type public.machine_status_result is 'set_machine_status result: the event now in force for the machine.';

create function public.set_machine_status(
  p_machine_id uuid,
  p_status     app.machine_status,
  p_client_id  uuid,
  p_reason     text default null)
returns public.machine_status_result language plpgsql volatile security definer set search_path = '' as $$
declare
  v_m      record;
  v_e      public.machine_status_events;
  v_reason text;
begin
  -- Role check FIRST: a missing machine and another tenant's machine give the same answer.
  select m.id, m.org_id, m.plant_id, m.active into v_m from public.machines m where m.id = p_machine_id;
  if v_m.id is null or not app.has_role(v_m.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'set_machine_status requires owner or manager on the machine''s plant';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  -- Idempotency: a retry returns the event it recorded (same plant only).
  select e.* into v_e from public.machine_status_events e where e.client_id = p_client_id;
  if v_e.id is not null then
    if v_e.plant_id = v_m.plant_id then
      return (v_e.id, v_e.machine_id, v_e.status, v_e.reason, v_e.occurred_at, false)::public.machine_status_result;
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  if p_status is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_status: down or up';
  end if;
  v_reason := app.clean_note(p_reason, 200, 'reason');
  if p_status = 'down' and v_reason is null then
    raise exception 'VALIDATION_FAILED' using detail = 'reason: required when marking a machine down (1–200 characters)';
  end if;
  if p_status = 'down' and not v_m.active then
    raise exception 'VALIDATION_FAILED' using detail = 'machine_id: the machine is inactive';
  end if;

  -- One status change at a time per machine.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('machine:' || v_m.id::text, 0));
  select e.* into v_e from public.machine_status_events e
   where e.machine_id = v_m.id and e.plant_id = v_m.plant_id
   order by e.occurred_at desc, e.seq desc limit 1;
  if coalesce(v_e.status, 'up') = p_status then
    -- Already in this status: nothing recorded, no alert. Returns the event in force (null when a
    -- machine that never went down is marked up).
    return (v_e.id, v_m.id, p_status, v_e.reason, v_e.occurred_at, false)::public.machine_status_result;
  end if;

  insert into public.machine_status_events as e (org_id, plant_id, machine_id, status, reason, entered_by, client_id)
  values (v_m.org_id, v_m.plant_id, v_m.id, p_status, v_reason, (select auth.uid()), p_client_id)
  on conflict (client_id) do nothing
  returning e.* into v_e;
  if v_e.id is null then   -- a concurrent retry won the race
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;

  if p_status = 'down' then
    -- Push hook: one undelivered alert per down event (see the header).
    insert into public.alert_events (org_id, plant_id, kind, subject_id, recipients)
    values (v_m.org_id, v_m.plant_id, 'machine_down', v_e.id, '{}');
  end if;
  return (v_e.id, v_e.machine_id, v_e.status, v_e.reason, v_e.occurred_at, true)::public.machine_status_result;
end;
$$;
comment on function public.set_machine_status(uuid, app.machine_status, uuid, text) is
  'Owner 2026-11-04 RPC (owner/manager; definer, role check first, plant-filtered): marks any machine down (p_reason required, 1–200 chars, no control characters; the machine must be active) or back up (p_reason optional). Appends a machine_status_events row; a down event also writes alert_events kind machine_down (subject = event id, recipients ''{}'') for the push sender. Same status as now → nothing recorded (changed=false). Idempotent on p_client_id (returns the recorded event, changed=false). Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.set_machine_status(uuid, app.machine_status, uuid, text) from public, anon;
grant execute on function public.set_machine_status(uuid, app.machine_status, uuid, text) to authenticated, service_role;

-- ── get_machine_status (read: every machine of a plant) ───────────────────
create function public.get_machine_status(p_plant_id uuid)
returns table (
  machine_id   uuid,
  machine_name text,
  kind         app.machine_kind,
  area_id      uuid,
  area_name    text,
  active       boolean,
  status       app.machine_status,   -- up when the machine never went down
  reason       text,                 -- the latest event's reason (down: why)
  since        timestamptz,          -- when the current status began; null = never went down
  server_time  timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_plant uuid;
begin
  select p.id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant is null or not app.has_role(v_plant, '{owner,manager,lead,viewer}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_machine_status requires a role on the plant';
  end if;
  return query
  select m.id, m.name, m.kind, m.area_id, a.name, m.active,
         coalesce(e.status, 'up'::app.machine_status), e.reason, e.occurred_at, pg_catalog.now()
    from public.machines m
    join public.areas a on a.id = m.area_id and a.plant_id = m.plant_id
    left join lateral (
      select x.status, x.reason, x.occurred_at from public.machine_status_events x
       where x.machine_id = m.id and x.plant_id = m.plant_id
       order by x.occurred_at desc, x.seq desc limit 1) e on true
   where m.plant_id = v_plant
     and (m.active or e.status = 'down')
   order by a.name, m.kind, m.name, m.id;
end;
$$;
comment on function public.get_machine_status(uuid) is
  'Owner 2026-11-04 read (owner/manager/lead/viewer of the plant; definer, role check first): one row per active machine of every kind (plus inactive machines still marked down), with area, status (down|up; up when never marked), the latest reason and since (when the current status began; null = never went down), and server_time for data age. Never returns who marked it. Errors: NOT_AUTHORIZED.';
revoke all on function public.get_machine_status(uuid) from public, anon;
grant execute on function public.get_machine_status(uuid) to authenticated, service_role;
