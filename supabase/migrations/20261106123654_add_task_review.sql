-- Task review (owner 2026-11-06, A): after a manager marks a task done, an owner reviews it. ONE review
-- by either owner (the owner and the owner's father both hold owner memberships) clears it for everyone.
-- Tasks are still never deleted.
--
-- * tasks.reviewed_at / reviewed_by. The update guard allows exactly two transitions: open → done
--   (unchanged) and done → reviewed (once; nothing else changes). reviewed_by is never selectable.
-- * review_task(p_task_id): owner only; the task must be done. Already reviewed → returned with
--   duplicate = true (the second owner's tap changes nothing), like complete_task.
-- * get_tasks: owners see open tasks + done-and-unreviewed tasks done in the last 7 days (reviewed ones
--   are hidden; p_include_done = true also lists reviewed tasks done in the last 7 days, as history).
--   Managers see only their OPEN tasks: a task leaves a manager's list as soon as it is done
--   (p_include_done is ignored for them).
-- * task_result gains reviewed_at, awaiting_review (done and not reviewed) and, for OWNER callers only
--   (owner 2026-11-06 "entered by" names), created_by_name / done_by_name / reviewed_by_name; null for
--   every other role.
-- * Push payloads for task kinds gain reviewed_at (no names). The Alerts tab treats task_done as current
--   until the task is reviewed (20261106123658_add_alert_dismissals).
-- Note: app.audit() is unchanged (owner instruction), so new tasks audit rows carry reviewed_by
-- (audit_log is owner-only).

alter table public.tasks
  add column reviewed_at timestamptz,
  add column reviewed_by uuid references auth.users(id),
  add constraint tasks_review_only_when_done check (reviewed_at is null or done_at is not null),
  add constraint tasks_review_has_reviewer check ((reviewed_at is null) = (reviewed_by is null));
create index tasks_reviewed_by_idx on public.tasks (reviewed_by);
create index tasks_awaiting_review_idx on public.tasks (plant_id, done_at) where done_at is not null and reviewed_at is null;
comment on column public.tasks.reviewed_at is
  'Owner 2026-11-06: when an owner reviewed the done task (one review clears it for every owner). Set once by review_task.';
comment on column public.tasks.reviewed_by is
  'Owner 2026-11-06: the owner who reviewed it. Never selectable by clients; named on owner screens only (get_tasks).';
grant select (reviewed_at) on public.tasks to authenticated;

create or replace function app.guard_task_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  if (new.org_id, new.plant_id, new.body, new.to_on_duty, new.assignee_user_ids, new.created_by, new.client_id, new.created_at)
     is distinct from
     (old.org_id, old.plant_id, old.body, old.to_on_duty, old.assignee_user_ids, old.created_by, old.client_id, old.created_at) then
    raise exception 'VALIDATION_FAILED' using detail = 'tasks: the task itself never changes';
  end if;
  if old.done_at is null then
    -- open → done (done_at, done_by, done_note); never straight to reviewed.
    if new.reviewed_at is not null or new.reviewed_by is not null then
      raise exception 'VALIDATION_FAILED' using detail = 'tasks: only a done task can be reviewed';
    end if;
  elsif old.reviewed_at is null then
    -- done → reviewed (reviewed_at, reviewed_by), once; the done fields stay as they are.
    if (new.done_at, new.done_by, new.done_note) is distinct from (old.done_at, old.done_by, old.done_note)
       or new.reviewed_at is null then
      raise exception 'VALIDATION_FAILED' using detail = 'tasks: a done task can only be marked reviewed';
    end if;
  else
    raise exception 'VALIDATION_FAILED' using detail = 'tasks: a reviewed task never changes';
  end if;
  return new;
end;
$$;
comment on function app.guard_task_update() is
  'BEFORE UPDATE on tasks: the only allowed changes are open → done (done_at, done_by, done_note) and done → reviewed (reviewed_at, reviewed_by), once each; the task itself never changes; VALIDATION_FAILED otherwise (owner 2026-11-06).';

-- ── task_result: review state + owner-only names ──────────────────────────
alter type public.task_result
  add attribute reviewed_at timestamptz,
  add attribute awaiting_review boolean,
  add attribute created_by_name text,
  add attribute done_by_name text,
  add attribute reviewed_by_name text;
comment on type public.task_result is
  'create_task / complete_task / review_task / get_tasks result. awaiting_review = done and not yet reviewed. created_by_name / done_by_name / reviewed_by_name: OWNER callers only (owner 2026-11-06), null for every other role. No user ids of who wrote / closed / reviewed.';

create or replace function app.task_result(p_id uuid, p_duplicate boolean)
returns public.task_result language sql stable set search_path = '' as $$
  select t.id, t.plant_id, t.body, t.to_on_duty, t.assignee_user_ids, t.created_at, t.done_at, t.done_note, p_duplicate,
         t.reviewed_at, t.done_at is not null and t.reviewed_at is null,
         case when o.is_owner then app.person_name(t.created_by, null, t.plant_id) end,
         case when o.is_owner then app.person_name(t.done_by, null, t.plant_id) end,
         case when o.is_owner then app.person_name(t.reviewed_by, null, t.plant_id) end
    from public.tasks t
   cross join lateral (select app.has_role(t.plant_id, '{owner}') as is_owner) o
   where t.id = p_id;
$$;
comment on function app.task_result(uuid, boolean) is
  'Builds public.task_result (internal; names only when the caller is an owner of the task''s plant).';
revoke all on function app.task_result(uuid, boolean) from public, anon, authenticated;

-- ── review_task ───────────────────────────────────────────────────────────
create function public.review_task(p_task_id uuid)
returns public.task_result language plpgsql volatile security definer set search_path = '' as $$
declare
  v_t public.tasks;
begin
  -- Role check FIRST: missing ids and other plants' tasks give the same NOT_AUTHORIZED.
  select t.* into v_t from public.tasks t where t.id = p_task_id;
  if v_t.id is null or not app.has_role(v_t.plant_id, '{owner}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'review_task requires owner on the task''s plant';
  end if;
  if v_t.done_at is null then
    raise exception 'VALIDATION_FAILED' using detail = 'task: not done yet';
  end if;
  if v_t.reviewed_at is not null then
    return app.task_result(v_t.id, true);
  end if;
  update public.tasks t
     set reviewed_at = pg_catalog.now(), reviewed_by = (select auth.uid())
   where t.id = v_t.id and t.plant_id = v_t.plant_id and t.done_at is not null and t.reviewed_at is null;
  if not found then
    return app.task_result(v_t.id, true);
  end if;
  return app.task_result(v_t.id, false);
end;
$$;
comment on function public.review_task(uuid) is
  'Owner 2026-11-06 RPC (OWNER only — either owner; definer, role check first, no existence oracle): marks a done task reviewed; one review clears it for every owner (it leaves get_tasks and its task alerts become finished). Already reviewed → returned with duplicate = true. Returns task_result. Errors: NOT_AUTHORIZED, VALIDATION_FAILED (not done yet).';
revoke all on function public.review_task(uuid) from public, anon;
grant execute on function public.review_task(uuid) to authenticated, service_role;

-- ── get_tasks ─────────────────────────────────────────────────────────────
create or replace function public.get_tasks(p_plant_id uuid, p_include_done boolean default false)
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
  select r.*
    from public.tasks t
   cross join lateral app.task_result(t.id, false) r
   where t.plant_id = v_plant
     and case when v_owner then
               t.done_at is null
               or (t.done_at > pg_catalog.now() - interval '7 days'
                   and (t.reviewed_at is null or coalesce(p_include_done, false)))
              else
               t.done_at is null and (select auth.uid()) = any (t.assignee_user_ids)
         end
   order by (t.done_at is not null), (t.reviewed_at is not null), t.created_at desc, t.id;
end;
$$;
comment on function public.get_tasks(uuid, boolean) is
  'Owner 2026-11-06 read (owner/manager; definer, role check first). Owners: the plant''s open tasks plus done-and-unreviewed tasks done in the last 7 days (awaiting_review = true); reviewed tasks are hidden unless p_include_done (then those done in the last 7 days are listed too). Managers: only their own OPEN tasks (a task leaves the list once done; p_include_done ignored). Order: open, then awaiting review, then reviewed; newest first. Names (created_by_name / done_by_name / reviewed_by_name) for owners only. No counts or per-person totals. Errors: NOT_AUTHORIZED.';

-- ── Push payload: task kinds carry reviewed_at (no names) ─────────────────
create or replace function app.alert_payload(p_alert public.alert_events)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
             'done_at', t.done_at, 'reviewed_at', t.reviewed_at)
      into v
      from public.tasks t
     where t.id = p_alert.subject_id and t.plant_id = p_alert.plant_id;
  end if;
  return coalesce(v, '{}'::jsonb);
end;
$$;
comment on function app.alert_payload(public.alert_events) is
  'Owner 2026-11-06: what a push notification may show, per kind (jsonb; no free text except a task''s own text to its assignees/owners; never names or done notes). machine_down: machine, area, reason_code + label, down_since, still_down. washer_idle: machine, area, idle_since, still_idle. route_loaded: route, load_time, load_date, loaded_at. task_assigned / task_done: task_id, body, to_on_duty, created_at, reminder, done_at, reviewed_at. Internal.';
