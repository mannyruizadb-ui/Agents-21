-- Owner 2026-11-05: machine-down reasons are DATA, editable in the app (Setup), not an enum.
--
-- * public.machine_down_reasons (per plant): code (stable key, lowercase), label_i18n (jsonb, 'en'
--   required; one key per language: languages are data), sort_order, active, requires_details.
--   Read by every role of the plant (and displays); INSERT / UPDATE by the OWNER only (column grants:
--   label_i18n, sort_order, active, requires_details; the code never changes because history points at
--   it). No deletes: deactivate. Audited.
-- * Every plant gets the 5 defaults (water_pump, soap_dispenser, wont_start, leaking, other; Spanish:
--   Bomba de agua, Dispensador de jabón, No arranca, Gotea, Otro): existing plants now, new plants by
--   trigger. 'other' requires details.
-- * machine_status_events.reason_code becomes text with a composite FK to (plant_id, code), so a
--   reason can never come from another plant. The table has no rows in the cloud yet (it ships with
--   this branch); locally the cast is lossless.
-- * set_machine_status takes p_reason_code text (an ACTIVE reason of the plant; details required when
--   requires_details). get_machine_status / get_washroom_board also return the reason's label_i18n,
--   with the same owner/manager-only hiding as the code and the details. The push helpers return
--   reason_label_i18n (appended), so custom reasons can be shown in the recipient's language.
-- * app.machine_down_reason (enum) is dropped.

create table public.machine_down_reasons (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null,
  plant_id         uuid not null,
  code             text not null check (code ~ '^[a-z][a-z0-9_]{1,39}$'),
  label_i18n       jsonb not null
                   check (jsonb_typeof(label_i18n) = 'object' and label_i18n ? 'en'
                          and jsonb_typeof(label_i18n -> 'en') = 'string'
                          and char_length(label_i18n ->> 'en') between 1 and 60
                          and app.is_clean_text(label_i18n ->> 'en')),
  sort_order       int not null default 0,
  active           boolean not null default true,
  requires_details boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  unique (plant_id, code),
  unique (id, plant_id)
);
alter table public.machine_down_reasons enable row level security;
create index machine_down_reasons_plant_org_idx on public.machine_down_reasons (plant_id, org_id);
comment on table public.machine_down_reasons is
  'Owner 2026-11-05: per-plant machine-down reasons (owner-editable data). code is the stable key stored on machine_status_events.reason_code; label_i18n holds the label per language (en required); requires_details forces free-text details (other). Deactivate, never delete.';

create function app.check_reason_labels()
returns trigger language plpgsql set search_path = '' as $$
begin
  if exists (select 1 from pg_catalog.jsonb_each(new.label_i18n) kv
              where pg_catalog.jsonb_typeof(kv.value) <> 'string'
                 or pg_catalog.char_length(kv.value #>> '{}') not between 1 and 60
                 or not app.is_clean_text(kv.value #>> '{}')
                 or not exists (select 1 from public.languages l where l.code = kv.key)) then
    raise exception 'VALIDATION_FAILED' using detail = 'label_i18n: one 1–60 character label per known language code';
  end if;
  return new;
end;
$$;
comment on function app.check_reason_labels() is
  'BEFORE INSERT/UPDATE on machine_down_reasons: every label_i18n key is a known language code and every value a clean 1–60 character string (VALIDATION_FAILED).';
revoke all on function app.check_reason_labels() from public, anon, authenticated;

create trigger machine_down_reasons_check_labels before insert or update of label_i18n on public.machine_down_reasons
  for each row execute function app.check_reason_labels();
create trigger machine_down_reasons_touch_updated_at before update on public.machine_down_reasons
  for each row execute function app.touch_updated_at();
create trigger machine_down_reasons_audit after insert or update on public.machine_down_reasons
  for each row execute function app.audit();

create policy machine_down_reasons_select on public.machine_down_reasons for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')) or (select app.is_display(plant_id)));
create policy machine_down_reasons_insert on public.machine_down_reasons for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner}')));
create policy machine_down_reasons_update on public.machine_down_reasons for update to authenticated
  using ((select app.has_role(plant_id, '{owner}')))
  with check ((select app.has_role(plant_id, '{owner}')));
revoke all on public.machine_down_reasons from anon, authenticated;
grant select on public.machine_down_reasons to authenticated;
grant insert (org_id, plant_id, code, label_i18n, sort_order, active, requires_details) on public.machine_down_reasons to authenticated;
grant update (label_i18n, sort_order, active, requires_details) on public.machine_down_reasons to authenticated;

-- ── Defaults for every plant ──────────────────────────────────────────────
create function app.add_default_machine_down_reasons()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.machine_down_reasons (org_id, plant_id, code, label_i18n, sort_order, requires_details)
  select new.org_id, new.id, d.code, d.label, d.sort_order, d.code = 'other'
    from (values
      ('water_pump',     '{"en":"Water pump","es":"Bomba de agua"}'::jsonb,               10),
      ('soap_dispenser', '{"en":"Soap dispenser","es":"Dispensador de jabón"}'::jsonb,    20),
      ('wont_start',     '{"en":"Won''t start","es":"No arranca"}'::jsonb,                30),
      ('leaking',        '{"en":"Leaking","es":"Gotea"}'::jsonb,                          40),
      ('other',          '{"en":"Other","es":"Otro"}'::jsonb,                             90)) as d(code, label, sort_order)
  on conflict (plant_id, code) do nothing;
  return null;
end;
$$;
comment on function app.add_default_machine_down_reasons() is
  'AFTER INSERT on plants: adds the 5 default machine-down reasons (water_pump, soap_dispenser, wont_start, leaking, other; en + es labels; other requires details). Owner 2026-11-05.';
revoke all on function app.add_default_machine_down_reasons() from public, anon, authenticated;
create trigger plants_default_machine_down_reasons after insert on public.plants
  for each row execute function app.add_default_machine_down_reasons();

-- Existing plants (DATA: the cloud's ADB plant and any other): same 5 defaults.
insert into public.machine_down_reasons (org_id, plant_id, code, label_i18n, sort_order, requires_details)
select p.org_id, p.id, d.code, d.label, d.sort_order, d.code = 'other'
  from public.plants p
 cross join (values
   ('water_pump',     '{"en":"Water pump","es":"Bomba de agua"}'::jsonb,               10),
   ('soap_dispenser', '{"en":"Soap dispenser","es":"Dispensador de jabón"}'::jsonb,    20),
   ('wont_start',     '{"en":"Won''t start","es":"No arranca"}'::jsonb,                30),
   ('leaking',        '{"en":"Leaking","es":"Gotea"}'::jsonb,                          40),
   ('other',          '{"en":"Other","es":"Otro"}'::jsonb,                             90)) as d(code, label, sort_order)
on conflict (plant_id, code) do nothing;

-- ── Drop everything typed with the enum (recreated below) ─────────────────
drop function public.claim_push_alerts();
drop function public.get_pending_push_alerts();
drop function app.claim_machine_down_alerts();
drop function app.pending_machine_down_alerts();
drop function public.get_washroom_board(uuid);
drop function public.get_machine_status(uuid);
drop function public.set_machine_status(uuid, app.machine_status, uuid, text, app.machine_down_reason);

-- ── machine_status_events.reason_code: enum → text + FK to the plant's reasons ──
alter table public.machine_status_events
  drop constraint machine_status_events_down_needs_code,
  drop constraint machine_status_events_code_only_for_down,
  drop constraint machine_status_events_other_needs_details;
alter table public.machine_status_events alter column reason_code type text using reason_code::text;
alter table public.machine_status_events
  add constraint machine_status_events_down_needs_code check (status <> 'down' or reason_code is not null) not valid,
  add constraint machine_status_events_code_only_for_down check (status = 'down' or reason_code is null),
  add constraint machine_status_events_other_needs_details check (reason_code is distinct from 'other' or reason is not null),
  add constraint machine_status_events_reason_fkey foreign key (plant_id, reason_code)
    references public.machine_down_reasons (plant_id, code);
create index machine_status_events_reason_idx on public.machine_status_events (plant_id, reason_code);
alter type public.machine_status_result alter attribute reason_code type text;
drop type app.machine_down_reason;

-- ── Recreated functions (text codes, labels appended) ─────────────────────
CREATE FUNCTION public.set_machine_status(p_machine_id uuid, p_status app.machine_status, p_client_id uuid, p_reason text DEFAULT NULL::text, p_reason_code text DEFAULT NULL::text)
 RETURNS public.machine_status_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_m      record;
  v_e      public.machine_status_events;
  v_reason text;
  v_code   text;
  v_r      public.machine_down_reasons;
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
      return (v_e.id, v_e.machine_id, v_e.status, v_e.reason, v_e.occurred_at, false, v_e.reason_code)::public.machine_status_result;
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  if p_status is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_status: down or up';
  end if;
  v_reason := app.clean_note(p_reason, 200, 'reason');
  -- Reason code (owner 2026-11-04): down needs a code; the free text is optional details, required
  -- for 'other'. Backward compatible: a down with only p_reason is recorded as 'other' + details.
  v_code := case when p_status = 'down' and p_reason_code is null and v_reason is not null then 'other'
                 else p_reason_code end;
  if p_status = 'down' and v_code is null then
    raise exception 'VALIDATION_FAILED' using detail = 'reason_code: required when marking a machine down (an active reason of the plant)';
  end if;
  if p_status = 'up' and v_code is not null then
    raise exception 'VALIDATION_FAILED' using detail = 'reason_code: only for down';
  end if;
  if v_code is not null then
    -- Reasons are per-plant data (owner 2026-11-05): the code must be an ACTIVE reason of this plant.
    select r.* into v_r from public.machine_down_reasons r
     where r.plant_id = v_m.plant_id and r.code = v_code and r.active;
    if v_r.id is null then
      raise exception 'VALIDATION_FAILED' using detail = 'reason_code: not an active machine-down reason of this plant';
    end if;
    if v_r.requires_details and v_reason is null then
      raise exception 'VALIDATION_FAILED' using detail = 'reason: details required for this reason (1–200 characters)';
    end if;
  end if;
  if v_code = 'other' and v_reason is null then
    raise exception 'VALIDATION_FAILED' using detail = 'reason: details required for reason_code other (1–200 characters)';
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
    return (v_e.id, v_m.id, p_status, v_e.reason, v_e.occurred_at, false, v_e.reason_code)::public.machine_status_result;
  end if;

  insert into public.machine_status_events as e (org_id, plant_id, machine_id, status, reason, reason_code, entered_by, client_id)
  values (v_m.org_id, v_m.plant_id, v_m.id, p_status, v_reason, v_code, (select auth.uid()), p_client_id)
  on conflict (client_id) do nothing
  returning e.* into v_e;
  if v_e.id is null then   -- a concurrent retry won the race
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;

  -- Push hook: one undelivered alert per down event, at most one per machine per 10 minutes (L5).
  if p_status = 'down' and not exists (
       select 1 from public.alert_events a
         join public.machine_status_events x on x.id = a.subject_id and x.plant_id = a.plant_id
        where a.kind = 'machine_down' and a.plant_id = v_m.plant_id and x.machine_id = v_m.id
          and a.sent_at > pg_catalog.now() - interval '10 minutes') then
    insert into public.alert_events (org_id, plant_id, kind, subject_id, recipients)
    values (v_m.org_id, v_m.plant_id, 'machine_down', v_e.id, '{}');
  end if;
  return (v_e.id, v_e.machine_id, v_e.status, v_e.reason, v_e.occurred_at, true, v_e.reason_code)::public.machine_status_result;
end;
$function$;
comment on function public.set_machine_status(uuid, app.machine_status, uuid, text, text) is
  'Owner 2026-11-04/05 RPC (owner/manager; definer, role check first, plant-filtered): marks any machine down with p_reason_code (the code of an ACTIVE row of machine_down_reasons for the plant; owner-editable data since 2026-11-05) and optional details p_reason (1–200 chars, no control characters; required when the reason has requires_details, e.g. other; a down with only p_reason is recorded as other) — the machine must be active — or back up (no code; p_reason optional). Appends a machine_status_events row. A down event also writes alert_events kind machine_down unless the same machine had one in the last 10 minutes. Same status as now → nothing recorded (changed=false). Idempotent on p_client_id. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.set_machine_status(uuid, app.machine_status, uuid, text, text) from public, anon;
grant execute on function public.set_machine_status(uuid, app.machine_status, uuid, text, text) to authenticated, service_role;

CREATE FUNCTION public.get_machine_status(p_plant_id uuid)
 RETURNS TABLE(machine_id uuid, machine_name text, kind app.machine_kind, area_id uuid, area_name text, active boolean, status app.machine_status, reason text, since timestamp with time zone, server_time timestamp with time zone, reason_code text, reason_label_i18n jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_plant  uuid;
  v_reason boolean;
begin
  select p.id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant is null or not app.has_role(v_plant, '{owner,manager,lead,viewer}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_machine_status requires a role on the plant';
  end if;
  v_reason := app.has_role(v_plant, '{owner,manager}');   -- L6: free-text reasons for owner/manager only
  return query
  select m.id, m.name, m.kind, m.area_id, a.name, m.active,
         coalesce(e.status, 'up'::app.machine_status), case when v_reason then e.reason end, e.occurred_at, pg_catalog.now(),
         case when v_reason then e.reason_code end,
         case when v_reason then e.label_i18n end
    from public.machines m
    join public.areas a on a.id = m.area_id and a.plant_id = m.plant_id
    left join lateral (
      select x.status, x.reason, x.reason_code, x.occurred_at, r.label_i18n from public.machine_status_events x
        left join public.machine_down_reasons r on r.plant_id = x.plant_id and r.code = x.reason_code
       where x.machine_id = m.id and x.plant_id = m.plant_id
       order by x.occurred_at desc, x.seq desc limit 1) e on true
   where m.plant_id = v_plant
     and (m.active or e.status = 'down')
   order by a.name, m.kind, m.name, m.id;
end;
$function$;
comment on function public.get_machine_status(uuid) is
  'Owner 2026-11-04 read (owner/manager/lead/viewer of the plant; definer, role check first): one row per active machine of every kind (plus inactive machines still marked down), with area, status (down|up; up when never marked), since (when the current status began; null = never went down), server_time for data age, and the latest event''s reason_code (preset, translated by the client) and reason (details) — both only for owner/manager, null for lead/viewer (security review L6). Never returns who marked it. Errors: NOT_AUTHORIZED. reason_code / reason_label_i18n (the plant''s reason label in every language, owner 2026-11-05) follow the same owner/manager-only rule.';
revoke all on function public.get_machine_status(uuid) from public, anon;
grant execute on function public.get_machine_status(uuid) to authenticated, service_role;

CREATE FUNCTION public.get_washroom_board(p_area_id uuid)
 RETURNS TABLE(machine_id uuid, machine_name text, load_factor numeric, status text, cycle_id uuid, wash_group_id uuid, wash_group_name text, wash_group_name_i18n jsonb, wash_group_color_hex text, is_rewash boolean, wash_formula_id uuid, formula_external_no text, formula_name text, cycle_minutes integer, started_at timestamp with time zone, expected_end_at timestamp with time zone, minutes_since_start integer, minutes_ready integer, queue_item_id uuid, next_queue_item_id uuid, next_is_assigned boolean, next_wash_group_id uuid, next_wash_group_name text, next_wash_group_name_i18n jsonb, next_wash_group_color_hex text, next_item_type_id uuid, next_item_name text, next_item_name_i18n jsonb, next_qty numeric, next_unit app.qty_unit, next_is_rush boolean, next_is_rewash boolean, next_loads_remaining integer, next_version integer, server_time timestamp with time zone, is_down boolean, down_reason text, down_since timestamp with time zone, down_reason_code text, down_reason_label_i18n jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_area   record;
  v_now    timestamptz := pg_catalog.now();
  v_reason boolean;
begin
  select a.id, a.plant_id into v_area from public.areas a where a.id = p_area_id;
  if v_area.id is null
     or not (app.has_role(v_area.plant_id, '{owner,manager,lead,viewer}')
             or (app.is_display(v_area.plant_id) and (app.my_device()).area_id = v_area.id)) then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_washroom_board requires a role on the area''s plant, or a display of this area';
  end if;
  v_reason := app.has_role(v_area.plant_id, '{owner,manager}');   -- L6: free-text reasons for owner/manager only

  return query
  select m.id, m.name, m.load_factor,
         case when c.id is null then 'idle'
              when f.cycle_minutes is null then 'unknown'
              when v_now < c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes) then 'running'
              else 'ready' end,
         c.id, c.wash_group_id, g.name, g.name_i18n, g.color_hex, c.is_rewash,
         c.wash_formula_id, f.external_no, f.name, f.cycle_minutes,
         c.started_at,
         c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes),
         (extract(epoch from (v_now - c.started_at)) / 60)::int,
         case when f.cycle_minutes is not null and v_now >= c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes)
              then (extract(epoch from (v_now - (c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes)))) / 60)::int end,
         c.queue_item_id,
         n.id, n.assigned_machine_id is not null, n.wash_group_id, ng.name, ng.name_i18n, ng.color_hex,
         n.item_type_id, ni.name, ni.name_i18n, n.qty, n.unit, n.is_rush, n.is_rewash,
         greatest(app.queue_loads_needed(n.wash_group_id, n.item_type_id, n.qty, n.unit) - n.loads_started, 0),
         n.version,
         v_now,
         coalesce(s.status = 'down', false),
         case when s.status = 'down' and v_reason then s.reason end,
         case when s.status = 'down' then s.occurred_at end,
         case when s.status = 'down' and v_reason then s.reason_code end,
         case when s.status = 'down' and v_reason then s.label_i18n end
    from public.machines m
    left join lateral (
      select e.status, e.reason, e.reason_code, e.occurred_at, r.label_i18n from public.machine_status_events e
        left join public.machine_down_reasons r on r.plant_id = e.plant_id and r.code = e.reason_code
       where e.machine_id = m.id and e.plant_id = m.plant_id
       order by e.occurred_at desc, e.seq desc
       limit 1) s on true
    left join lateral (
      select w.* from public.washer_cycles w
       where w.machine_id = m.id and w.plant_id = m.plant_id and w.voided_at is null
       order by w.started_at desc, w.id desc
       limit 1) c on true
    left join public.wash_groups g on g.id = c.wash_group_id
    left join public.wash_formulas f on f.id = c.wash_formula_id
    left join lateral (
      select q.* from public.queue_items q
       where q.area_id = m.area_id and q.plant_id = m.plant_id
         and q.status in ('queued', 'in_progress')
         and (q.assigned_machine_id = m.id or q.assigned_machine_id is null)
         and s.status is distinct from 'down'            -- a down washer gets no NEXT
       order by (q.assigned_machine_id is not null) desc, q.is_rush desc, q.position, q.id
       limit 1) n on true
    left join public.wash_groups ng on ng.id = n.wash_group_id
    left join public.item_types ni on ni.id = n.item_type_id
   where m.area_id = v_area.id and m.plant_id = v_area.plant_id and m.kind = 'washer' and m.active
   order by m.name, m.id;
end;
$function$;
comment on function public.get_washroom_board(uuid) is
  'D1/G6 read (owner/manager/lead/viewer, or a display of this area): one row per ACTIVE washer of the area, in name order: the current (latest live) cycle with group, formula, started_at, expected_end_at = started_at + cycle_minutes, status idle|running|ready|unknown (no cycle time), minutes_ready; and NEXT = the top open item assigned to this washer, else the top open unassigned item (the same unassigned item can be NEXT on several washers: "next free washer"). is_down / down_reason / down_since (owner 2026-11-04; down_reason only for owner/manager, null for lead, viewer and display: security review L6): a down washer takes precedence over status, shows no NEXT, and refuses start-taps. server_time for data age. No per-person data. down_reason_code (owner 2026-11-04): the preset reason (water_pump | soap_dispenser | wont_start | leaking | other), translated by the client; same per-role hiding as down_reason. down_reason_label_i18n (owner 2026-11-05): the reason''s label in every language, same hiding as down_reason_code.';
revoke all on function public.get_washroom_board(uuid) from public, anon;
grant execute on function public.get_washroom_board(uuid) to authenticated, service_role;

CREATE FUNCTION app.pending_machine_down_alerts()
 RETURNS TABLE(alert_id uuid, alert_created timestamp with time zone, org_id uuid, plant_id uuid, plant_name text, machine_id uuid, machine_name text, machine_kind app.machine_kind, area_name text, reason_code text, down_since timestamp with time zone, still_down boolean, subscription_id uuid, user_id uuid, language text, endpoint text, p256dh text, auth text, reason_label_i18n jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select a.id, a.sent_at, a.org_id, a.plant_id, p.name, m.id, m.name, m.kind, ar.name, e.reason_code, e.occurred_at,
         app.machine_is_down_at(m.id, m.plant_id, pg_catalog.now()),
         s.id, s.user_id, pr.language, s.endpoint, s.p256dh, s.auth, dr.label_i18n
    from public.alert_events a
    join public.plants p on p.id = a.plant_id and p.org_id = a.org_id
    join public.machine_status_events e on e.id = a.subject_id and e.plant_id = a.plant_id and e.status = 'down'
    join public.machines m on m.id = e.machine_id and m.plant_id = e.plant_id
    join public.areas ar on ar.id = m.area_id and ar.plant_id = m.plant_id
    join public.push_subscriptions s on s.plant_id = a.plant_id and s.org_id = a.org_id and s.revoked_at is null
    join auth.users u on u.id = s.user_id and (u.banned_until is null or u.banned_until <= pg_catalog.now())
    left join public.profiles pr on pr.user_id = s.user_id
    left join public.machine_down_reasons dr on dr.plant_id = e.plant_id and dr.code = e.reason_code
   where a.kind = 'machine_down'
     and a.recipients = '{}'
     and a.sent_at > pg_catalog.now() - interval '1 hour'
     and exists (
       select 1 from public.memberships mm
        where mm.user_id = s.user_id and mm.org_id = a.org_id
          and (mm.plant_id = a.plant_id or mm.plant_id is null)
          and mm.revoked_at is null and mm.role in ('owner', 'manager') and mm.notify_machine_down)
   order by a.sent_at, a.id, s.id;
$function$;
comment on function app.pending_machine_down_alerts() is
  'Owner 2026-11-04 (service role only): undelivered machine_down alerts (recipients ''{}'', ≤ 1 h old) × the active push subscriptions of their plant''s owner/manager members with notify_machine_down (not banned). Columns: alert_id, alert_created, org_id, plant_id, plant_name, machine_id, machine_name, machine_kind, area_name, reason_code (never the free text), down_since, still_down, subscription_id, user_id, language, endpoint, p256dh, auth, reason_label_i18n (the plant''s preset label in every language; owner 2026-11-05).';
revoke all on function app.pending_machine_down_alerts() from public, anon, authenticated;
grant execute on function app.pending_machine_down_alerts() to service_role;

CREATE FUNCTION app.claim_machine_down_alerts()
 RETURNS TABLE(alert_id uuid, alert_created timestamp with time zone, org_id uuid, plant_id uuid, plant_name text, machine_id uuid, machine_name text, machine_kind app.machine_kind, area_name text, reason_code text, down_since timestamp with time zone, still_down boolean, subscription_id uuid, user_id uuid, language text, endpoint text, p256dh text, auth text, reason_label_i18n jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare
  v_ids uuid[];
begin
  select coalesce(pg_catalog.array_agg(x.id), '{}') into v_ids
    from (select a.id from public.alert_events a
           where a.kind = 'machine_down' and a.recipients = '{}'
             and a.id in (select p.alert_id from app.pending_machine_down_alerts() p)
           order by a.sent_at, a.id
             for update skip locked) x;
  if pg_catalog.cardinality(v_ids) = 0 then
    return;
  end if;
  -- Rows first (the pending view filters on recipients = '{}'), then mark them claimed.
  return query select p.* from app.pending_machine_down_alerts() p where p.alert_id = any (v_ids);
  update public.alert_events a set recipients = '{claimed}' where a.id = any (v_ids);
end;
$function$;
comment on function app.claim_machine_down_alerts() is
  'Security review M1 (2026-11-04; service role only): atomically claims the pending machine_down alerts that have recipients (FOR UPDATE SKIP LOCKED; recipients := ''{claimed}'') and returns their rows in the shape of app.pending_machine_down_alerts() (never the free-text reason). A concurrent or later claim gets nothing for them. Record the final recipients with app.mark_alert_delivered.';
revoke all on function app.claim_machine_down_alerts() from public, anon, authenticated;
grant execute on function app.claim_machine_down_alerts() to service_role;

CREATE FUNCTION public.get_pending_push_alerts()
 RETURNS TABLE(alert_id uuid, alert_created timestamp with time zone, org_id uuid, plant_id uuid, plant_name text, machine_id uuid, machine_name text, machine_kind app.machine_kind, area_name text, reason_code text, down_since timestamp with time zone, still_down boolean, subscription_id uuid, user_id uuid, language text, endpoint text, p256dh text, auth text, reason_label_i18n jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select * from app.pending_machine_down_alerts();
$function$;
comment on function public.get_pending_push_alerts() is
  'Owner 2026-11-04 (SERVICE ROLE ONLY; for the send-alerts Edge Function via PostgREST): same rows as app.pending_machine_down_alerts(). No client role may execute it.';
revoke all on function public.get_pending_push_alerts() from public, anon, authenticated;
grant execute on function public.get_pending_push_alerts() to service_role;

CREATE FUNCTION public.claim_push_alerts()
 RETURNS TABLE(alert_id uuid, alert_created timestamp with time zone, org_id uuid, plant_id uuid, plant_name text, machine_id uuid, machine_name text, machine_kind app.machine_kind, area_name text, reason_code text, down_since timestamp with time zone, still_down boolean, subscription_id uuid, user_id uuid, language text, endpoint text, p256dh text, auth text, reason_label_i18n jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select * from app.claim_machine_down_alerts();
$function$;
comment on function public.claim_push_alerts() is
  'Security review M1 (2026-11-04; SERVICE ROLE ONLY, for the send-alerts Edge Function via PostgREST): app.claim_machine_down_alerts(). Claim, send, then mark_push_alert_delivered. No client role may execute it.';
revoke all on function public.claim_push_alerts() from public, anon, authenticated;
grant execute on function public.claim_push_alerts() to service_role;

