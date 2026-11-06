-- Tasks (owner 2026-11-06, C): the owner (or the father, also an owner) sends a short job to a named
-- manager or to "the manager on duty" ("check all parked trucks"). The assignee gets a push at once and
-- every 10 minutes until it is done; marking it done (optional note) notifies the owners.
-- Work direction only: NO per-person statistics, counts, completion times or rankings anywhere (HR /
-- legal note, CLAUDE.md). Nothing here aggregates tasks by person.
--
-- * public.tasks: body (1–200), assignee_user_ids (the named manager, or the managers on duty when it
--   was sent, resolved at once), done_at / done_note. created_by and done_by are kept for the audit but
--   never selectable. Client writes only through create_task / complete_task (client_id idempotency);
--   a task is never deleted and, once done, never changes.
-- * Reads: the owner sees the plant's tasks; anyone else only tasks assigned to them.
-- * Push: task_assigned (dedupe_key = reminder number; 0 = first) to the assignees while open;
--   app.generate_task_reminders (every minute via app.alert_tick) adds a reminder 10 minutes after the
--   last one, for up to 24 hours. task_done to the owners. Payloads carry the task text (to its
--   assignees, and back to the owners who wrote it), never the done note or names.

create table public.tasks (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null,
  plant_id          uuid not null,
  body              text not null check (char_length(body) between 1 and 200 and app.is_clean_text(body)),
  to_on_duty        boolean not null,
  assignee_user_ids uuid[] not null check (cardinality(assignee_user_ids) between 1 and 50),
  created_by        uuid references auth.users(id),
  client_id         uuid not null unique,
  created_at        timestamptz not null default now(),
  done_at           timestamptz,
  done_by           uuid references auth.users(id),
  done_note         text check (char_length(done_note) between 1 and 200 and app.is_clean_text(done_note)),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  constraint tasks_note_only_when_done check (done_at is not null or done_note is null)
);
alter table public.tasks enable row level security;
create index tasks_plant_org_idx on public.tasks (plant_id, org_id);
create index tasks_created_by_idx on public.tasks (created_by);
create index tasks_done_by_idx on public.tasks (done_by);
create index tasks_open_idx on public.tasks (plant_id, created_at) where done_at is null;
create index tasks_assignees_idx on public.tasks using gin (assignee_user_ids);
comment on table public.tasks is
  'Owner 2026-11-06: short jobs from the owner to a named manager or the manager(s) on duty; open until the assignee marks them done (optional note). Work direction only: never aggregated or reported per person. Written only by create_task / complete_task.';

create function app.guard_task_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.done_at is not null
     or (new.org_id, new.plant_id, new.body, new.to_on_duty, new.assignee_user_ids, new.created_by, new.client_id, new.created_at)
        is distinct from
        (old.org_id, old.plant_id, old.body, old.to_on_duty, old.assignee_user_ids, old.created_by, old.client_id, old.created_at) then
    raise exception 'VALIDATION_FAILED' using detail = 'tasks: only an open task can be marked done; nothing else changes';
  end if;
  return new;
end;
$$;
comment on function app.guard_task_update() is
  'BEFORE UPDATE on tasks: the only allowed change is open → done (done_at, done_by, done_note); VALIDATION_FAILED otherwise.';
revoke all on function app.guard_task_update() from public, anon, authenticated;
create trigger tasks_guard_update before update on public.tasks for each row execute function app.guard_task_update();
create trigger tasks_prevent_delete before delete on public.tasks for each row execute function app.prevent_mutation();
create trigger tasks_prevent_truncate before truncate on public.tasks for each statement execute function app.prevent_delete();
create trigger tasks_audit after insert or update on public.tasks for each row execute function app.audit();

create policy tasks_select on public.tasks for select to authenticated
  using ((select app.has_role(plant_id, '{owner}'))
         or ((select auth.uid()) = any (assignee_user_ids) and (select app.has_role(plant_id, '{owner,manager}'))));
revoke all on public.tasks from anon, authenticated;
grant select (id, org_id, plant_id, body, to_on_duty, assignee_user_ids, client_id, created_at, done_at, done_note)
  on public.tasks to authenticated;

create type public.task_result as (
  task_id           uuid,
  plant_id          uuid,
  body              text,
  to_on_duty        boolean,
  assignee_user_ids uuid[],
  created_at        timestamptz,
  done_at           timestamptz,
  done_note         text,
  duplicate         boolean
);
comment on type public.task_result is 'create_task / complete_task / get_tasks result (no created_by / done_by).';

create function app.task_result(p_id uuid, p_duplicate boolean)
returns public.task_result language sql stable set search_path = '' as $$
  select t.id, t.plant_id, t.body, t.to_on_duty, t.assignee_user_ids, t.created_at, t.done_at, t.done_note, p_duplicate
    from public.tasks t where t.id = p_id;
$$;
comment on function app.task_result(uuid, boolean) is 'Builds public.task_result (internal).';
revoke all on function app.task_result(uuid, boolean) from public, anon, authenticated;

-- ── create_task ───────────────────────────────────────────────────────────
create function public.create_task(p_plant_id uuid, p_body text, p_client_id uuid, p_assignee_user_id uuid default null)
returns public.task_result language plpgsql volatile security definer set search_path = '' as $$
declare
  v_plant record;
  v_body  text;
  v_to    uuid[];
  v_t     public.tasks;
begin
  select p.id, p.org_id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant.id is null or not app.has_role(v_plant.id, '{owner}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'create_task requires owner on the plant';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  select t.* into v_t from public.tasks t where t.client_id = p_client_id;
  if v_t.id is not null then
    if v_t.plant_id = v_plant.id then
      return app.task_result(v_t.id, true);
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  v_body := app.clean_note(p_body, 200, 'body');
  if v_body is null then
    raise exception 'VALIDATION_FAILED' using detail = 'body: 1–200 characters';
  end if;
  if p_assignee_user_id is not null then
    if not exists (select 1 from public.memberships m
                    where m.user_id = p_assignee_user_id and m.role = 'manager' and m.revoked_at is null
                      and m.org_id = v_plant.org_id and (m.plant_id is null or m.plant_id = v_plant.id)) then
      raise exception 'VALIDATION_FAILED' using detail = 'assignee: not an active manager of this plant';
    end if;
    v_to := array[p_assignee_user_id];
  else
    select coalesce(pg_catalog.array_agg(u order by u), '{}') into v_to from app.managers_on_duty(v_plant.id, pg_catalog.now()) u;
    if pg_catalog.cardinality(v_to) = 0 then
      raise exception 'VALIDATION_FAILED' using detail = 'no manager is on duty now: choose a manager by name';
    end if;
  end if;

  insert into public.tasks as t (org_id, plant_id, body, to_on_duty, assignee_user_ids, created_by, client_id)
  values (v_plant.org_id, v_plant.id, v_body, p_assignee_user_id is null, v_to, (select auth.uid()), p_client_id)
  on conflict (client_id) do nothing
  returning t.* into v_t;
  if v_t.id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  insert into public.alert_events (org_id, plant_id, kind, subject_id, recipients, dedupe_key)
  values (v_t.org_id, v_t.plant_id, 'task_assigned', v_t.id, '{}', '0');
  return app.task_result(v_t.id, false);
end;
$$;
comment on function public.create_task(uuid, text, uuid, uuid) is
  'Owner 2026-11-06 RPC (owner only; definer, role check first): sends a task (p_body 1–200 chars) to p_assignee_user_id (an active manager of the plant) or, when null, to the managers on duty now (VALIDATION_FAILED when none). Pushes task_assigned at once and every 10 minutes until done (max 24 h). Idempotent on p_client_id (duplicate=true). Returns task_result. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.create_task(uuid, text, uuid, uuid) from public, anon;
grant execute on function public.create_task(uuid, text, uuid, uuid) to authenticated, service_role;

-- ── complete_task ─────────────────────────────────────────────────────────
create function public.complete_task(p_task_id uuid, p_note text default null)
returns public.task_result language plpgsql volatile security definer set search_path = '' as $$
declare
  v_t    public.tasks;
  v_note text;
begin
  select t.* into v_t from public.tasks t where t.id = p_task_id;
  if v_t.id is null
     or not (app.has_role(v_t.plant_id, '{owner}')
             or ((select auth.uid()) = any (v_t.assignee_user_ids) and app.has_role(v_t.plant_id, '{manager}'))) then
    raise exception 'NOT_AUTHORIZED' using detail = 'complete_task requires the task''s assignee or an owner';
  end if;
  if v_t.done_at is not null then
    return app.task_result(v_t.id, true);
  end if;
  v_note := app.clean_note(p_note, 200, 'note');
  update public.tasks t
     set done_at = pg_catalog.now(), done_by = (select auth.uid()), done_note = v_note
   where t.id = v_t.id and t.done_at is null;
  if not found then
    return app.task_result(v_t.id, true);
  end if;
  insert into public.alert_events (org_id, plant_id, kind, subject_id, recipients)
  values (v_t.org_id, v_t.plant_id, 'task_done', v_t.id, '{}');
  return app.task_result(v_t.id, false);
end;
$$;
comment on function public.complete_task(uuid, text) is
  'Owner 2026-11-06 RPC (the task''s assignee, or an owner; definer, role check first): marks an open task done with an optional note (≤ 200 chars) and notifies the owners (task_done; the note is not in the push). Already done → returns it (duplicate=true). Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.complete_task(uuid, text) from public, anon;
grant execute on function public.complete_task(uuid, text) to authenticated, service_role;

-- ── get_tasks ─────────────────────────────────────────────────────────────
create function public.get_tasks(p_plant_id uuid, p_include_done boolean default false)
returns setof public.task_result language plpgsql stable security definer set search_path = '' as $$
declare
  v_plant uuid;
  v_owner boolean;
begin
  select p.id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant is null or not app.has_role(v_plant, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_tasks requires owner or manager on the plant';
  end if;
  v_owner := app.has_role(v_plant, '{owner}');
  return query
  select t.id, t.plant_id, t.body, t.to_on_duty, t.assignee_user_ids, t.created_at, t.done_at, t.done_note, false
    from public.tasks t
   where t.plant_id = v_plant
     and (v_owner or (select auth.uid()) = any (t.assignee_user_ids))
     and (t.done_at is null or (coalesce(p_include_done, false) and t.done_at > pg_catalog.now() - interval '7 days'))
   order by (t.done_at is not null), t.created_at desc, t.id;
end;
$$;
comment on function public.get_tasks(uuid, boolean) is
  'Owner 2026-11-06 read (owner: the plant''s tasks; manager: tasks assigned to them; definer, role check first): open tasks, plus those done in the last 7 days when p_include_done. Newest first, open before done. No counts or per-person totals. Errors: NOT_AUTHORIZED.';
revoke all on function public.get_tasks(uuid, boolean) from public, anon;
grant execute on function public.get_tasks(uuid, boolean) to authenticated, service_role;

-- ── Reminders every 10 minutes ────────────────────────────────────────────
create function app.generate_task_reminders()
returns int language plpgsql volatile security definer set search_path = '' as $$
declare
  v_n int;
begin
  insert into public.alert_events (org_id, plant_id, kind, subject_id, recipients, dedupe_key)
  select t.org_id, t.plant_id, 'task_assigned', t.id, '{}', (last.n + 1)::text
    from public.tasks t
    join lateral (
      select max(a.dedupe_key::int) as n, max(a.sent_at) as at
        from public.alert_events a
       where a.kind = 'task_assigned' and a.subject_id = t.id and a.plant_id = t.plant_id) last on true
   where t.done_at is null
     and t.created_at > pg_catalog.now() - interval '24 hours'
     and last.at <= pg_catalog.now() - interval '10 minutes'
  on conflict (kind, subject_id, shift_instance_id, dedupe_key) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
comment on function app.generate_task_reminders() is
  'Owner 2026-11-06 (pg_cron via app.alert_tick; service role only): for each open task younger than 24 h whose last task_assigned alert is ≥ 10 minutes old, writes the next reminder (dedupe_key = reminder number). Returns reminders written.';
revoke all on function app.generate_task_reminders() from public, anon, authenticated;
grant execute on function app.generate_task_reminders() to service_role;

-- ── Security review note 3 (2026-11-06): washer idle counts from the later of the cycle's finish and
--    the current shift's start (so the first alarm of a shift does not report the night as idle). ──
CREATE OR REPLACE FUNCTION app.generate_washer_idle_alerts()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_n int;
begin
  insert into public.alert_events (org_id, plant_id, kind, subject_id, recipients, dedupe_key)
  select m.org_id, m.plant_id, 'washer_idle', m.id, '{}', c.id::text
    from public.machines m
    join lateral (
      select w.id, w.started_at, w.wash_formula_id from public.washer_cycles w
       where w.machine_id = m.id and w.plant_id = m.plant_id and w.voided_at is null
       order by w.started_at desc, w.id desc limit 1) c on true
    join public.wash_formulas f on f.id = c.wash_formula_id and f.cycle_minutes is not null
    join lateral (
      select max(si.starts_at) as shift_start from public.shift_instances si
       where si.area_id = m.area_id and si.plant_id = m.plant_id and si.skipped_at is null
         and si.starts_at <= pg_catalog.now() and si.ends_at > pg_catalog.now()) cur on cur.shift_start is not null
   where m.kind = 'washer' and m.active
     -- Idle time counts from the later of the cycle's finish and the current shift's start.
     and greatest(c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes), cur.shift_start)
         <= pg_catalog.now() - interval '15 minutes'
     and not app.machine_is_down_at(m.id, m.plant_id, pg_catalog.now())
     and exists (select 1 from public.queue_items q
                  where q.area_id = m.area_id and q.plant_id = m.plant_id
                    and q.status in ('queued', 'in_progress')
                    and (q.assigned_machine_id = m.id or q.assigned_machine_id is null))
  on conflict (kind, subject_id, shift_instance_id, dedupe_key) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$function$;
comment on function app.generate_washer_idle_alerts() is
  'Owner 2026-11-06 (pg_cron via app.alert_tick; service role only): one washer_idle alert per washer per idle period (dedupe_key = the finished cycle) when an active, not-down washer has been idle ≥ 15 min, counted from the later of its last cycle''s finish and the start of its area''s current shift, nothing newer started, and the queue has work for it. Returns alerts written.';

-- ── Push wiring ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION app.alert_recipient_users(p_alert alert_events)
 RETURNS SETOF uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_alert.kind = 'machine_down' then
    return query
      select distinct m.user_id from public.memberships m
        join public.plants p on p.id = p_alert.plant_id and p.org_id = m.org_id
       where m.revoked_at is null and m.role in ('owner', 'manager') and m.notify_machine_down
         and (m.plant_id is null or m.plant_id = p_alert.plant_id);
  elsif p_alert.kind = 'washer_idle' then
    return query
      select u from app.plant_owner_users(p_alert.plant_id) u
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
  end if;
  -- Other kinds are added by their own migrations.
end;
$function$;

CREATE OR REPLACE FUNCTION app.alert_payload(p_alert alert_events)
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
             'machine_id', m.id, 'machine_name', m.name, 'machine_kind', m.kind, 'area_name', ar.name,
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
             'machine_id', m.id, 'machine_name', m.name, 'area_name', ar.name,
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
             'done_at', t.done_at)
      into v
      from public.tasks t
     where t.id = p_alert.subject_id and t.plant_id = p_alert.plant_id;
  end if;
  return coalesce(v, '{}'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION app.alert_tick()
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  begin
    perform app.generate_washer_idle_alerts();
  exception when others then
    raise warning 'generate_washer_idle_alerts failed: % (%)', sqlerrm, sqlstate;
  end;
  begin
    perform app.generate_task_reminders();
  exception when others then
    raise warning 'generate_task_reminders failed: % (%)', sqlerrm, sqlstate;
  end;
  return app.dispatch_send_alerts();
end;
$function$;
comment on function app.alert_tick() is
  'Owner 2026-11-06 (pg_cron every minute; service role only): runs the alert generators (washer idle, task reminders), then app.dispatch_send_alerts(). A failing generator only warns.';
