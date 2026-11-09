-- Spanish machine names (owner 2026-11-09, review item 10). Machines had only a plain `name`; the app turned
-- "Washer N" / "Dryer N" into "Lavadora N" / "Secadora N" by pattern (src/lib/seededNames.ts), but every other
-- machine (Ironer, Boiler, …) stayed English for the Spanish-first crew and managers.
--
-- 1. public.machines.name_i18n jsonb (same pattern as wash_groups / item_types / customers): language → name,
--    validated by app.check_languages (enabled language codes, 1–60 clean characters each). The owner edits it
--    in Setup → Machines (machines INSERT/UPDATE stay owner-only; column grant added; audited by machines_audit).
-- 2. Reads that name machines carry it too, so screens and pushes can show it:
--    * public.get_machine_status: new last column machine_name_i18n (drop + create: the return type changes;
--      same body, grants and comment otherwise);
--    * app.alert_payload: machine_name_i18n in the machine_down and washer_idle payloads.
--    get_washroom_board / get_queue only name washers, which the app's "Washer N" pattern already covers.
-- 3. DATA, ADB plant (seed.sql calls the same function for fresh databases): app.apply_machine_spanish_names(plant)
--    sets name_i18n.es where the machine has NO es name yet (an owner edit is never overwritten), from the
--    English name: Ironer → Planchadora, Folder → Dobladora, Boiler → Caldera, Compressor → Compresor,
--    Water pump → Bomba de agua, Soap machine → Máquina de jabón, Wrapping machine → Empacadora,
--    Washer N → Lavadora N, Dryer N → Secadora N. Any other name is left without an es value (the app shows the
--    plain name). Skipped when the plant does not enable es. Idempotent; audited (postgres: no actor).

-- ── 1. Column, grant, language check ──────────────────────────────────────
alter table public.machines
  add column name_i18n jsonb not null default '{}'::jsonb
    constraint machines_name_i18n_check check (jsonb_typeof(name_i18n) = 'object');
comment on column public.machines.name_i18n is
  'Owner 2026-11-09: the machine''s name per language code ({"es":"Planchadora"}); missing key = show `name`. Enabled languages only, 1–60 clean characters (app.check_languages). Owner-edited in Setup → Machines.';
grant update (name_i18n) on public.machines to authenticated;

create or replace function app.check_languages()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_enabled text[];
  v_code    text;
  v_val     jsonb;
  v_max     int := 60;
  v_map     jsonb;
begin
  if tg_table_name = 'plants' then
    if exists (select 1 from unnest(new.enabled_languages) c
                where not exists (select 1 from public.languages l where l.code = c)) then
      raise exception 'VALIDATION_FAILED' using detail = 'enabled_languages: unknown language code';
    end if;
    if not (new.default_language = any (new.enabled_languages)) then
      raise exception 'VALIDATION_FAILED' using detail = 'default_language: must be in enabled_languages';
    end if;
    return new;
  end if;

  if tg_table_name = 'profiles' then
    -- A user's language must be enabled in at least one plant they belong to (if any yet).
    select coalesce(array_agg(distinct l), '{}') into v_enabled
      from public.memberships m
      join public.plants p on p.org_id = m.org_id and (m.plant_id is null or m.plant_id = p.id)
      cross join lateral unnest(p.enabled_languages) l
     where m.user_id = new.user_id and m.revoked_at is null;
    if cardinality(v_enabled) > 0 and not (new.language = any (v_enabled)) then
      raise exception 'VALIDATION_FAILED' using detail = 'language: not enabled for any of the user''s plants';
    end if;
    return new;
  end if;

  -- Plant-scoped tables: devices, item_types, wash_groups, customers, machines, display_messages, entry_staff.
  -- Security M2: never validate (and so never leak) another tenant's plant settings. A client
  -- without a role on the row's plant passes through and RLS rejects the row (42501). Service
  -- role / postgres (auth.uid() null) are always validated.
  if (select auth.uid()) is not null and not app.has_role(new.plant_id, '{owner,manager,lead,viewer}') then
    return new;
  end if;
  select p.enabled_languages into v_enabled from public.plants p where p.id = new.plant_id;
  if v_enabled is null then
    return new;  -- the plant FK reports the missing plant
  end if;

  if tg_table_name = 'devices' then
    if exists (select 1 from unnest(new.display_languages) c where not (c = any (v_enabled))) then
      raise exception 'VALIDATION_FAILED' using detail = 'display_languages: not enabled for the plant';
    end if;
    return new;
  elsif tg_table_name = 'entry_staff' then
    if not (new.language = any (v_enabled)) then
      raise exception 'VALIDATION_FAILED' using detail = 'language: not enabled for the plant';
    end if;
    return new;
  elsif tg_table_name in ('item_types', 'wash_groups', 'customers', 'machines') then
    v_map := new.name_i18n;
  elsif tg_table_name = 'display_messages' then
    if not (new.body_lang = any (v_enabled)) then
      raise exception 'VALIDATION_FAILED' using detail = 'body_lang: not enabled for the plant';
    end if;
    v_map := new.body_i18n;
    v_max := 140;
  else
    raise exception 'app.check_languages() is not configured for table %', tg_table_name;
  end if;

  for v_code, v_val in select key, value from jsonb_each(v_map) loop
    if not (v_code = any (v_enabled)) then
      raise exception 'VALIDATION_FAILED' using detail = format('i18n: language %s not enabled for the plant', v_code);
    end if;
    if jsonb_typeof(v_val) <> 'string'
       or char_length(v_val #>> '{}') not between 1 and v_max
       or not app.is_clean_text(v_val #>> '{}') then
      raise exception 'VALIDATION_FAILED' using detail = format('i18n: value for %s must be 1–%s clean characters', v_code, v_max);
    end if;
  end loop;
  return new;
end;
$function$;
comment on function app.check_languages() is
  '§4.5 BEFORE INSERT/UPDATE on plants, profiles, devices, item_types, wash_groups, customers, machines (2026-11-09), display_messages, entry_staff: language codes exist and are enabled for the plant; i18n values 1–60 (140 for messages) chars.';
create trigger machines_check_languages before insert or update of name_i18n, plant_id on public.machines
  for each row execute function app.check_languages();

-- ── 2a. get_machine_status: + machine_name_i18n ───────────────────────────
drop function public.get_machine_status(uuid);
create function public.get_machine_status(p_plant_id uuid)
 RETURNS TABLE(machine_id uuid, machine_name text, kind app.machine_kind, area_id uuid, area_name text, active boolean, status app.machine_status, reason text, since timestamp with time zone, server_time timestamp with time zone, reason_code text, reason_label_i18n jsonb, status_by_name text, machine_name_i18n jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_plant  uuid;
  v_reason boolean;
  v_owner  boolean;
begin
  select p.id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant is null or not app.has_role(v_plant, '{owner,manager,lead,viewer}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_machine_status requires a role on the plant';
  end if;
  v_reason := app.has_role(v_plant, '{owner,manager}');   -- L6: free-text reasons for owner/manager only
  v_owner  := app.has_role(v_plant, '{owner}');           -- names: owner only (2026-11-06)
  return query
  select m.id, m.name, m.kind, m.area_id, a.name, m.active,
         coalesce(e.status, 'up'::app.machine_status), case when v_reason then e.reason end, e.occurred_at, pg_catalog.now(),
         case when v_reason then e.reason_code end,
         case when v_reason then e.label_i18n end,
         case when v_owner and e.status is not null then app.person_name(e.entered_by, null, m.plant_id) end,
         m.name_i18n
    from public.machines m
    join public.areas a on a.id = m.area_id and a.plant_id = m.plant_id
    left join lateral (
      select x.status, x.reason, x.reason_code, x.occurred_at, x.entered_by, r.label_i18n from public.machine_status_events x
        left join public.machine_down_reasons r on r.plant_id = x.plant_id and r.code = x.reason_code
       where x.machine_id = m.id and x.plant_id = m.plant_id
       order by x.occurred_at desc, x.seq desc limit 1) e on true
   where m.plant_id = v_plant
     and (m.active or e.status = 'down')
   order by a.name, m.kind, m.name, m.id;
end;
$function$;
comment on function public.get_machine_status(uuid) is
  'Owner 2026-11-04 read (owner/manager/lead/viewer of the plant; definer, role check first): one row per active machine of every kind (plus inactive machines still marked down), with area, status (down|up; up when never marked), since (when the current status began; null = never went down), server_time for data age, and the latest event''s reason_code (preset, translated by the client), reason_label_i18n and reason (details) — owner/manager only, null for lead/viewer (security review L6). status_by_name (owner 2026-11-06): who marked the current status (down or fixed), for OWNER callers only, null for every other role. machine_name_i18n (2026-11-09): the machine''s name per language ({} = show machine_name). Errors: NOT_AUTHORIZED.';
revoke all on function public.get_machine_status(uuid) from public, anon;
grant execute on function public.get_machine_status(uuid) to authenticated, service_role;

-- ── 2b. alert_payload: + machine_name_i18n for machine_down and washer_idle ──
create or replace function app.alert_payload(p_alert alert_events)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v jsonb;
begin
  if p_alert.kind = 'machine_down' then
    select pg_catalog.jsonb_build_object(
             'machine_id', m.id, 'machine_name', m.name, 'machine_name_i18n', m.name_i18n, 'machine_kind', m.kind,
             'area_name', ar.name,
             'reason_code', e.reason_code, 'reason_label_i18n', r.label_i18n, 'down_since', e.occurred_at,
             'still_down', app.machine_is_down_at(m.id, m.plant_id, pg_catalog.now()))
      into v
      from public.machine_status_events e
      join public.machines m on m.id = e.machine_id and m.plant_id = e.plant_id
      join public.areas ar on ar.id = m.area_id and ar.plant_id = m.plant_id
      left join public.machine_down_reasons r on r.plant_id = e.plant_id and r.code = e.reason_code
     where e.id = p_alert.subject_id and e.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'washer_idle' then
    select pg_catalog.jsonb_build_object(
             'machine_id', m.id, 'machine_name', m.name, 'machine_name_i18n', m.name_i18n, 'area_name', ar.name,
             'idle_since', greatest(c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes),
                                    (select max(si.starts_at) from public.shift_instances si
                                      where si.area_id = m.area_id and si.plant_id = m.plant_id and si.skipped_at is null
                                        and si.starts_at <= p_alert.sent_at and si.ends_at > p_alert.sent_at)),
             'still_idle', not exists (select 1 from public.washer_cycles w2
                                        where w2.machine_id = m.id and w2.plant_id = m.plant_id and w2.voided_at is null
                                          and (w2.started_at, w2.id) > (c.started_at, c.id)))
      into v
      from public.machines m
      join public.areas ar on ar.id = m.area_id and ar.plant_id = m.plant_id
      left join public.washer_cycles c on c.id::text = p_alert.dedupe_key and c.plant_id = m.plant_id
      left join public.wash_formulas f on f.id = c.wash_formula_id
     where m.id = p_alert.subject_id and m.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'route_loaded' then
    select pg_catalog.jsonb_build_object(
             'route_id', r.id, 'route_name', r.name, 'load_time', r.load_time, 'load_date', e.load_date,
             'loaded_at', e.occurred_at)
      into v
      from public.route_load_events e
      join public.routes r on r.id = e.route_id and r.plant_id = e.plant_id
     where e.id = p_alert.subject_id and e.plant_id = p_alert.plant_id;
  elsif p_alert.kind in ('task_assigned', 'task_done') then
    -- The task's own text goes to its assignees (task_assigned) and back to the owners (task_done).
    -- The done note and any names never go in a payload.
    select pg_catalog.jsonb_build_object(
             'task_id', t.id, 'body', t.body, 'to_on_duty', t.to_on_duty, 'created_at', t.created_at,
             'reminder', case when p_alert.kind = 'task_assigned' then coalesce(p_alert.dedupe_key, '0')::int end,
             'done_at', t.done_at, 'reviewed_at', t.reviewed_at)
      into v
      from public.tasks t
     where t.id = p_alert.subject_id and t.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'customer_delivery' then
    -- Owner 2026-11-06: customer, when, and per line the group + bins (+ loads); no names, no note.
    select pg_catalog.jsonb_build_object(
             'delivery_id', d.id, 'customer_id', c.id, 'customer_name', c.name, 'customer_name_i18n', c.name_i18n,
             'delivered_at', d.delivered_at, 'voided', d.voided_at is not null,
             'total_bins', (select sum(l.bins) from public.customer_delivery_lines l
                             where l.delivery_id = d.id and l.plant_id = d.plant_id),
             'lines', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                                  'wash_group_id', g.id, 'wash_group_name', g.name, 'wash_group_name_i18n', g.name_i18n,
                                  'bins', l.bins, 'loads', l.loads) order by l.line_no)
                                  from public.customer_delivery_lines l
                                  join public.wash_groups g on g.id = l.wash_group_id and g.plant_id = l.plant_id
                                 where l.delivery_id = d.id and l.plant_id = d.plant_id), '[]'::jsonb))
      into v
      from public.customer_deliveries d
      join public.customers c on c.id = d.customer_id and c.plant_id = d.plant_id
     where d.id = p_alert.subject_id and d.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'estimate_entered' then
    -- The batch: estimates the same account recorded on the plant within 10 minutes of the FIRST one (the
    -- alert's subject; its recorded_at, else the alert's sent_at for rows from before recorded_at). The
    -- account is only used to group; it is never in the payload.
    select pg_catalog.jsonb_build_object(
             'first_estimate_id', f.id,
             'count', (select count(*) from public.soil_estimates e
                        where e.plant_id = f.plant_id and e.entered_by = f.entered_by
                          and e.recorded_at >= coalesce(f.recorded_at, p_alert.sent_at)
                          and e.recorded_at < coalesce(f.recorded_at, p_alert.sent_at) + interval '10 minutes'),
             'estimates', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                                      'estimate_id', e.id, 'wash_group_id', g.id, 'wash_group_name', g.name,
                                      'wash_group_name_i18n', g.name_i18n, 'customer_id', g.customer_id,
                                      'qty', e.qty, 'unit', e.unit,
                                      'qty_loads', app.to_loads(e.wash_group_id, null, e.qty, e.unit),
                                      'entered_at', e.entered_at) order by e.recorded_at, e.id)
                                      from public.soil_estimates e
                                      join public.wash_groups g on g.id = e.wash_group_id and g.plant_id = e.plant_id
                                     where e.plant_id = f.plant_id and e.entered_by = f.entered_by
                                       and e.recorded_at >= coalesce(f.recorded_at, p_alert.sent_at)
                                       and e.recorded_at < coalesce(f.recorded_at, p_alert.sent_at) + interval '10 minutes'), '[]'::jsonb))
      into v
      from public.soil_estimates f
     where f.id = p_alert.subject_id and f.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'rewash_added' then
    select pg_catalog.jsonb_build_object(
             'queue_item_id', q.id, 'area_id', ar.id, 'area_name', ar.name,
             'wash_group_id', g.id, 'wash_group_name', g.name, 'wash_group_name_i18n', g.name_i18n,
             'customer_id', q.customer_id, 'qty', q.qty, 'unit', q.unit,
             'qty_loads', app.to_loads(q.wash_group_id, q.item_type_id, q.qty, q.unit),
             'status', q.status, 'created_at', q.created_at)
      into v
      from public.queue_items q
      join public.areas ar on ar.id = q.area_id and ar.plant_id = q.plant_id
      join public.wash_groups g on g.id = q.wash_group_id and g.plant_id = q.plant_id
     where q.id = p_alert.subject_id and q.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'account_locked' then
    -- 2026-11-07: a security event for owners. The username IS the subject (mapped accounts only; an
    -- owner's own email is never shown). No IP, no typed values, no password detail.
    select pg_catalog.jsonb_build_object(
             'user_id', u.id, 'username', app.login_username(u.email),
             'failures', (select s.max_attempts from app.sign_in_limits() s where s.kind = 'login'),
             'locked_until', pg_catalog.to_timestamp(p_alert.dedupe_key::bigint),
             'still_locked', exists (select 1 from public.sign_in_lockouts l
                                      where l.key_hash = app.sign_in_key('login', u.email)
                                        and l.locked_until > pg_catalog.now()))
      into v
      from auth.users u
     where u.id = p_alert.subject_id and p_alert.dedupe_key ~ '^[0-9]{1,12}$';
  end if;
  return coalesce(v, '{}'::jsonb);
end;
$function$;
comment on function app.alert_payload(public.alert_events) is
  'Owner 2026-11-06: what an alert may show, per kind (jsonb; no free text except a task''s own text to its assignees/owners; never names or notes, except account_locked''s username for owners). machine_down: machine (+ machine_name_i18n, 2026-11-09), area, reason_code + label, down_since, still_down. washer_idle: machine (+ machine_name_i18n), area, idle_since, still_idle. route_loaded: route, load_time, load_date, loaded_at. task_assigned / task_done: task_id, body, to_on_duty, created_at, reminder, done_at, reviewed_at. customer_delivery: delivery_id, customer, delivered_at, voided, total_bins, lines[group, bins, loads]. estimate_entered: first_estimate_id, count, estimates[group, customer_id, qty, unit, qty_loads, entered_at] (the batch window starts at the first estimate''s recorded_at). rewash_added: queue item, area, group, customer_id, qty, unit, qty_loads, status, created_at. account_locked (2026-11-07): user_id, username (mapped accounts only, else null), failures, locked_until, still_locked. off_queue_start removed 2026-11-07 (empty payload). Internal.';

-- ── 3. DATA: Spanish names for the seeded machines ────────────────────────
create function app.es_machine_name(p_name text)
returns text language sql immutable set search_path = '' as $$
  select case
    when v.n ~* '^washer \w{1,10}$' then 'Lavadora ' || substr(v.n, 8)
    when v.n ~* '^dryer \w{1,10}$'  then 'Secadora ' || substr(v.n, 7)
    else case lower(v.n)
      when 'ironer'           then 'Planchadora'
      when 'folder'           then 'Dobladora'
      when 'boiler'           then 'Caldera'
      when 'compressor'       then 'Compresor'
      when 'water pump'       then 'Bomba de agua'
      when 'soap machine'     then 'Máquina de jabón'
      when 'wrapping machine' then 'Empacadora'
    end
  end
  from (select regexp_replace(btrim(p_name), '\s+', ' ', 'g') as n) v;
$$;
comment on function app.es_machine_name(text) is
  'Owner 2026-11-09: Spanish name for a seeded English machine name (Ironer → Planchadora, Folder → Dobladora, Boiler → Caldera, Compressor → Compresor, Water pump → Bomba de agua, Soap machine → Máquina de jabón, Wrapping machine → Empacadora, Washer N → Lavadora N, Dryer N → Secadora N; case and extra spaces ignored). Null for any other name. Used by app.apply_machine_spanish_names. Postgres only.';
revoke all on function app.es_machine_name(text) from public, anon, authenticated;

create function app.apply_machine_spanish_names(p_plant_id uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_named  int := 0;
  v_result jsonb;
begin
  if p_plant_id is null or not exists (select 1 from public.plants p where p.id = p_plant_id) then
    raise exception 'VALIDATION_FAILED' using detail = 'apply_machine_spanish_names: unknown plant';
  end if;
  if not exists (select 1 from public.plants p where p.id = p_plant_id and 'es' = any (p.enabled_languages)) then
    raise notice 'apply_machine_spanish_names(%): es not enabled, nothing to do', p_plant_id;
    return jsonb_build_object('named', 0, 'skipped', 'es not enabled');
  end if;

  update public.machines m
     set name_i18n = m.name_i18n || jsonb_build_object('es', app.es_machine_name(m.name))
   where m.plant_id = p_plant_id
     and not (m.name_i18n ? 'es')
     and app.es_machine_name(m.name) is not null;
  get diagnostics v_named = row_count;

  v_result := jsonb_build_object(
    'named', v_named,
    -- Machines still without a Spanish name (an owner-added name the mapping does not know).
    'without_es', (select coalesce(jsonb_agg(m.name order by m.name), '[]'::jsonb) from public.machines m
                    where m.plant_id = p_plant_id and not (m.name_i18n ? 'es')));
  raise notice 'apply_machine_spanish_names(%): %', p_plant_id, v_result;
  return v_result;
end;
$$;
comment on function app.apply_machine_spanish_names(uuid) is
  'Owner 2026-11-09 (Spanish machine names), one-shot data change for one plant, shared by the data migration 20261109215633 (cloud, ADB plant) and seed.sql: sets name_i18n.es = app.es_machine_name(name) on every machine (active or not) that has no es name yet; owner-entered es names are never overwritten. Skips a plant without es enabled. Idempotent. Returns/NOTICEs the count and the machines still without an es name. VALIDATION_FAILED on an unknown plant. Postgres only.';
revoke all on function app.apply_machine_spanish_names(uuid) from public, anon, authenticated;

-- The ADB plant (no row on a fresh database: seed.sql calls the function itself).
select app.apply_machine_spanish_names(p.id)
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami';
