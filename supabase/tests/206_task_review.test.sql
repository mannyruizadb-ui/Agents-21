-- Owner 2026-11-06 (A): task review. done → reviewed once, by either owner; one review clears it for
-- every owner. get_tasks: owners see open + done-and-unreviewed (7 days); managers only their open tasks.
-- task_done stays live in the Alerts tab until reviewed. Names (D) on owner calls only.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(24);

create function pg_temp.cid(n int) returns uuid language sql immutable as $$
  select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;
$$;
create function pg_temp.t(n int) returns uuid language sql stable as $$ select id from public.tasks where client_id = pg_temp.cid(n) $$;
grant execute on function pg_temp.cid(int), pg_temp.t(int) to authenticated, anon;
-- The second owner (the owner's father): a plant-scoped owner membership, no profile name.
insert into public.memberships (user_id, org_id, plant_id, role) values (pg_temp.id('ownerP'), pg_temp.id('orgA'), pg_temp.id('plantA'), 'owner');
create function pg_temp.mine(p_user text, p_include boolean default false) returns text language sql as $$
  select pg_temp.val_as(p_user, format($q$select coalesce(string_agg(body || ':' || awaiting_review, ',' order by body), '-')
                                          from public.get_tasks(pg_temp.id('plantA'), %L)$q$, p_include));
$$;

select is(pg_temp.run_as('owner', $$select public.create_task(pg_temp.id('plantA'), 'Check the trucks', pg_temp.cid(1), pg_temp.id('manager'))$$), '1', 'task 1 to the manager');
select is(pg_temp.run_as('owner', $$select public.create_task(pg_temp.id('plantA'), 'Sweep the dock', pg_temp.cid(2), pg_temp.id('manager'))$$), '1', 'task 2 to the manager');
select is(pg_temp.run_as('manager', $$select public.complete_task(pg_temp.t(1), 'done')$$), '1', 'the manager marks task 1 done');

-- ══ get_tasks ════════════════════════════════════════════════════════════
select is(array[pg_temp.mine('manager'), pg_temp.mine('manager', true)], array['Sweep the dock:false', 'Sweep the dock:false'],
  'manager: only open tasks; a done task leaves the list at once (p_include_done ignored)');
select is(pg_temp.mine('owner'), 'Check the trucks:true,Sweep the dock:false', 'owner: open + done awaiting review');
select is(pg_temp.val_as('owner', $$select string_agg(body, ',' order by ord) from public.get_tasks(pg_temp.id('plantA')) with ordinality as x(task_id, plant_id, body, to_on_duty, assignee_user_ids, created_at, done_at, done_note, duplicate, reviewed_at, awaiting_review, created_by_name, done_by_name, reviewed_by_name, ord)$$),
  'Sweep the dock,Check the trucks', 'open first, then awaiting review');

-- ══ review_task: role check first, no oracle ═════════════════════════════
select is(array[
  pg_temp.run_as('manager', $$select public.review_task(pg_temp.t(1))$$),
  pg_temp.run_as('lead', $$select public.review_task(pg_temp.t(1))$$),
  pg_temp.run_as('viewer', $$select public.review_task(pg_temp.t(1))$$),
  pg_temp.run_as('display', $$select public.review_task(pg_temp.t(1))$$),
  pg_temp.run_as('ownerB', $$select public.review_task(pg_temp.t(1))$$),
  pg_temp.run_as('ownerB', $$select public.review_task(gen_random_uuid())$$),
  pg_temp.run_as('anon', $$select public.review_task(pg_temp.t(1))$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'review_task: owners only; another tenant''s owner and unknown ids get the same NOT_AUTHORIZED');
select is(pg_temp.run_as('owner', $$select public.review_task(pg_temp.t(2))$$), 'VALIDATION_FAILED', 'an open task cannot be reviewed');

-- task_done is live for the owners until reviewed.
select is(pg_temp.val_as('owner', $$select still_current::text || '/' || can_clear from public.get_my_alerts(pg_temp.id('plantA')) where kind = 'task_done'$$),
  'true/false', 'task_done: still current (awaiting review), cannot be cleared');

select is(pg_temp.val_as('ownerP', $$select row((r).reviewed_at is not null, (r).awaiting_review, (r).duplicate)::text from (select public.review_task(pg_temp.t(1)) r) x$$),
  '(t,f,f)', 'the second owner (the father) reviews it');
select is(pg_temp.val_as('owner', $$select (public.review_task(pg_temp.t(1))).duplicate::text$$), 'true',
  'one review clears it for everyone: the other owner''s review changes nothing');
select is(array[pg_temp.mine('owner'), pg_temp.mine('ownerP'), pg_temp.mine('owner', true)],
  array['Sweep the dock:false', 'Sweep the dock:false', 'Check the trucks:false,Sweep the dock:false'],
  'reviewed tasks leave both owners'' lists (p_include_done shows them as history)');
select is(pg_temp.val_as('owner', $$select still_current::text || '/' || can_clear from public.get_my_alerts(pg_temp.id('plantA')) where kind = 'task_done'$$),
  'false/true', 'a reviewed task''s task_done alert is finished');
select is((select count(*)::int from public.audit_log where entity = 'tasks' and entity_id = pg_temp.t(1)), 3,
  'audited: created, done, reviewed');

-- ══ Guard: exactly open → done → reviewed ════════════════════════════════
select is(array[
  pg_temp.as_service($$update public.tasks set reviewed_at = now() where id = pg_temp.t(1)$$),
  pg_temp.as_service($$update public.tasks set done_note = 'edited' where id = pg_temp.t(1)$$),
  pg_temp.as_service($$update public.tasks set reviewed_at = null, reviewed_by = null where id = pg_temp.t(1)$$),
  pg_temp.as_service($$update public.tasks set done_at = now(), done_by = pg_temp.id('manager'), reviewed_at = now(), reviewed_by = pg_temp.id('owner') where id = pg_temp.t(2)$$),
  pg_temp.as_service($$delete from public.tasks where id = pg_temp.t(1)$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}',
  'guard: a reviewed task never changes (no re-review, no un-review, no note edit); open cannot jump to reviewed; never deleted');
select is(pg_temp.run_as('manager', $$select public.complete_task(pg_temp.t(2))$$), '1', 'task 2 done');
select is(array[
  pg_temp.as_service($$update public.tasks set done_note = 'changed', reviewed_at = now(), reviewed_by = pg_temp.id('owner') where id = pg_temp.t(2)$$),
  pg_temp.as_service($$update public.tasks set reviewed_at = now() where id = pg_temp.t(2)$$)],
  '{VALIDATION_FAILED,23514}', 'done → reviewed changes only the review fields, and needs both reviewed_at and reviewed_by');
select is(array[pg_temp.run_as('owner', $$select reviewed_by from public.tasks$$),
                pg_temp.run_as('owner', $$select reviewed_at from public.tasks$$, true),
                pg_temp.run_as('owner', $$update public.tasks set reviewed_at = now() where id = pg_temp.t(2)$$)],
  '{42501,2,42501}', 'reviewed_by is never selectable; reviewed_at is; no direct writes');

-- ══ Names (D): owners only ═══════════════════════════════════════════════
-- 2026-11-07: the fallback is the USERNAME of a mapped login, never part of another email.
update auth.users set email = 'plant-owner@accounts.adbheadquarters.com' where id = 'aaaaaaaa-0000-0000-0000-00000000000c';
select is(pg_temp.val_as('owner', $$select concat_ws('|', created_by_name, done_by_name, reviewed_by_name) from public.get_tasks(pg_temp.id('plantA'), true) where body = 'Check the trucks'$$),
  'Owner A|Manager A|plant-owner', 'owner: who sent, closed and reviewed it (profile name, else the username)');
select is(pg_temp.val_as('owner', $$select concat_ws('|', created_by_name, coalesce(done_by_name, '-'), coalesce(reviewed_by_name, '-')) from public.get_tasks(pg_temp.id('plantA')) where body = 'Sweep the dock'$$),
  'Owner A|Manager A|-', 'awaiting review: no reviewer yet');
select is(pg_temp.run_as('owner', $$select public.create_task(pg_temp.id('plantA'), 'Lock the gate', pg_temp.cid(3), pg_temp.id('manager'))$$), '1', 'task 3 to the manager');
select is(pg_temp.val_as('manager', $$select count(*)::text from public.get_tasks(pg_temp.id('plantA')) where created_by_name is not null or done_by_name is not null or reviewed_by_name is not null$$),
  '0', 'manager: names are null');
select is(pg_temp.val_as('manager', $$select coalesce((r).created_by_name, 'null') || '/' || coalesce((r).done_by_name, 'null') from (select public.complete_task(pg_temp.t(3)) r) x$$),
  'null/null', 'complete_task returns no names to a manager');
select is(pg_temp.val_as('owner', $$select (public.review_task(pg_temp.t(3))).done_by_name$$), 'Manager A', 'review_task returns names to the owner');

select * from finish();
rollback;
