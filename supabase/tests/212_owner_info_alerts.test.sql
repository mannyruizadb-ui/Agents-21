-- Owner information alerts and levels (owner 2026-11-06, C): estimate_entered (one per batch),
-- rewash_added (a manager's rewash), per-owner levels push | quiet | off (memberships.alert_levels,
-- set_alert_level: SELF-ONLY since 2026-11-07), quiet never pushed, off hidden, all informational and
-- clearable, no names in payloads. off_queue_start was removed (owner 2026-11-07): starts write no alert.
begin;
\ir _fixtures.psql
-- The entry-PIN RPCs are service_role only since 20261110104605 (asserted in 229_audit_fixes_2026_11_10).
-- This file still exercises their kept-for-history logic as signed-in roles: grant inside this rolled-back transaction.
grant execute on function public.start_staff_session(uuid, text) to authenticated;
select plan(40);

insert into public.entry_staff (id, org_id, plant_id, display_name, pin_hash) values
  ('b0000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), 'Ben', extensions.crypt('1470', extensions.gen_salt('bf')));
insert into public.memberships (user_id, org_id, plant_id, role) values (pg_temp.id('ownerP'), pg_temp.id('orgA'), pg_temp.id('plantA'), 'owner');
create function pg_temp.ben() returns uuid language sql as $$
  select (public.start_staff_session('b0000000-0000-0000-0000-0000000000a2', '1470')).staff_session_id;
$$;
create function pg_temp.mid(p text) returns uuid language sql stable security definer as $$
  select m.id from public.memberships m where m.user_id = pg_temp.id(p) and m.revoked_at is null order by m.created_at limit 1;
$$;
create function pg_temp.k() returns text language sql immutable as $$ select repeat('B', 86) || 'A' $$;
create function pg_temp.a() returns text language sql immutable as $$ select 'abcdefghij_-KLMNOPQRST' $$;
-- The kinds the caller sees in the Alerts tab (owner information kinds only), e.g. 'estimate_entered=2'.
create function pg_temp.my(p_user text) returns text language sql as $$
  select pg_temp.val_as(p_user, $q$select coalesce(string_agg(kind || '=' || n, ',' order by kind), '-')
                                     from (select kind, count(*) n from public.get_my_alerts(pg_temp.id('plantA'), 200)
                                            where kind in ('estimate_entered', 'rewash_added', 'off_queue_start') group by kind) x$q$);
$$;
grant execute on function pg_temp.ben(), pg_temp.mid(text) to authenticated, anon;
insert into public.push_subscriptions (org_id, plant_id, user_id, endpoint, p256dh, auth) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('owner'), 'https://fcm.googleapis.com/fcm/send/owner', pg_temp.k(), pg_temp.a()),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('manager'), 'https://fcm.googleapis.com/fcm/send/manager', pg_temp.k(), pg_temp.a());

-- ══ Levels: storage and defaults ═════════════════════════════════════════
select is((select alert_levels from public.memberships where id = pg_temp.mid('owner')),
  '{"customer_delivery":"push","estimate_entered":"quiet","rewash_added":"quiet"}'::jsonb,
  'defaults: customer_delivery push; estimate_entered, rewash_added quiet (account_locked: push via app.alert_level_default)');
select is(array[
  pg_temp.as_service($$update public.memberships set alert_levels = '{"machine_down":"push"}' where id = pg_temp.mid('owner')$$),
  pg_temp.as_service($$update public.memberships set alert_levels = '{"rewash_added":"loud"}' where id = pg_temp.mid('owner')$$),
  pg_temp.as_service($$update public.memberships set alert_levels = '{"rewash_added":1}' where id = pg_temp.mid('owner')$$),
  pg_temp.as_service($$update public.memberships set alert_levels = '[]' where id = pg_temp.mid('owner')$$),
  pg_temp.as_service($$update public.memberships set alert_levels = '{}' where id = pg_temp.mid('ownerP')$$)],
  '{23514,23514,23514,23514,1}', 'CHECK: only owner information kinds, only push | quiet | off ({} = all defaults)');
select is(array[
  pg_temp.run_as('manager', $$update public.memberships set alert_levels = '{}' where id = pg_temp.mid('owner')$$),
  pg_temp.run_as('owner', $$update public.memberships set alert_levels = '{"rewash_added":"loud"}' where id = pg_temp.mid('owner')$$)],
  '{0,23514}', 'direct writes: owners only (memberships RLS), and the CHECK still applies (the app uses set_alert_level)');
select is(pg_temp.reads($$select alert_levels from public.memberships where id = pg_temp.mid('owner')$$),
  '{1,0,0,0,0,0,0,42501}', 'alert_levels is readable where the membership is (an org-wide owner membership: org owners only)');

-- ══ set_alert_level ══════════════════════════════════════════════════════
select is(pg_temp.writes($$select public.set_alert_level(pg_temp.mid('owner'), 'rewash_added', 'quiet')$$),
  '{1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'set_alert_level: owners only; managers, leads, viewers, displays, other tenants refused; anon cannot call');
select is(array[
  pg_temp.run_as('ownerP', $$select public.set_alert_level(pg_temp.mid('owner'), 'rewash_added', 'off')$$),
  pg_temp.run_as('owner',  $$select public.set_alert_level(pg_temp.mid('ownerP'), 'rewash_added', 'push')$$),
  pg_temp.run_as('ownerP', $$select public.set_alert_level(pg_temp.mid('ownerP'), 'rewash_added', 'push')$$),
  pg_temp.run_as('owner',  $$select public.set_alert_level(gen_random_uuid(), 'rewash_added', 'push')$$),
  pg_temp.run_as('ownerB', $$select public.set_alert_level(pg_temp.mid('ownerP'), 'rewash_added', 'off')$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,1,NOT_AUTHORIZED,NOT_AUTHORIZED}',
  'self-only (2026-11-07): neither owner changes the other''s level (not even an org owner); each sets their own; unknown and foreign ids: same NOT_AUTHORIZED');
select is(array[
  pg_temp.run_as('owner', $$select public.set_alert_level(pg_temp.mid('manager'), 'rewash_added', 'push')$$),
  pg_temp.run_as('owner', $$select public.set_alert_level(pg_temp.mid('owner'), 'off_queue_start', 'push')$$),
  pg_temp.run_as('owner', $$select public.set_alert_level(pg_temp.mid('owner'), 'machine_down', 'push')$$),
  pg_temp.run_as('owner', $$select public.set_alert_level(pg_temp.mid('owner'), 'rewash_added', 'loud')$$),
  pg_temp.run_as('owner', $$select public.set_alert_level(pg_temp.mid('owner'), null, 'push')$$),
  pg_temp.run_as('owner', $$select public.set_alert_level(pg_temp.mid('owner'), 'rewash_added', null)$$)],
  '{NOT_AUTHORIZED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}',
  'a manager''s membership is not the caller''s own; only the four owner information kinds (off_queue_start removed; existing kinds keep their switches); only push | quiet | off');
select is(pg_temp.val_as('ownerP', $$select (public.set_alert_level(pg_temp.mid('ownerP'), 'account_locked', 'off')).alert_levels ->> 'account_locked'$$),
  'off', 'returns the membership with the new level');
-- A revoked plant membership of the (org-wide) owner: still the owner's own, still owned by them.
insert into public.memberships (id, user_id, org_id, plant_id, role, revoked_at)
values ('a1000000-0000-0000-0000-0000000000f1', pg_temp.id('owner'), pg_temp.id('orgA'), pg_temp.id('plantA'), 'owner', now());
select is(pg_temp.run_as('owner', $$select public.set_alert_level('a1000000-0000-0000-0000-0000000000f1', 'rewash_added', 'push')$$),
  'VALIDATION_FAILED', 'a revoked membership: VALIDATION_FAILED');
select is((select count(*)::int from public.audit_log where entity = 'memberships' and action = 'memberships.update'
             and before -> 'alert_levels' is distinct from after -> 'alert_levels'), 3,
  'level changes are audited (3 real changes so far)');

-- ══ estimate_entered: one alert per batch ════════════════════════════════
select is(array[
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 2, 'load', 'e3000000-0000-0000-0000-000000000001', pg_temp.ben())$$),
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gMat'), 0, 'load', 'e3000000-0000-0000-0000-000000000002', pg_temp.ben())$$),
  pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 2, 'load', 'e3000000-0000-0000-0000-000000000001', null)$$)],
  '{1,1,1}', 'a manager enters a batch of 2 estimates (2 PINs), then a retry of the first');
select is((select count(*)::int from public.alert_events where kind = 'estimate_entered'), 1, 'the batch is ONE estimate_entered alert (the retry adds none)');
select is((select app.alert_payload(a) #>> '{count}' || ':' || (select string_agg(e ->> 'wash_group_name' || '=' || (e ->> 'qty') || ' ' || (e ->> 'unit'), ',' order by e ->> 'wash_group_name')
                                                       from jsonb_array_elements(app.alert_payload(a) -> 'estimates') e)
             from public.alert_events a where a.kind = 'estimate_entered'),
  '2:Mats=0.00 load,Napkins=2.00 load', 'payload: the batch''s groups and quantities');
select ok((select app.alert_payload(a)::text !~* '(Ben|Manager A|entered_by|staff)' from public.alert_events a where a.kind = 'estimate_entered'),
  'payload: no names');
select is(pg_temp.run_as('owner', $$select public.record_soil_estimate(pg_temp.id('gTowel'), 1, 'load', 'e3000000-0000-0000-0000-000000000003', pg_temp.ben())$$), '1',
  'another account enters an estimate …');
select is((select count(*)::int from public.alert_events where kind = 'estimate_entered'), 2, '… which is its own batch');
-- Batches are anchored on the first estimate's recorded_at (2026-11-07): move both back in time.
alter table public.soil_estimates disable trigger soil_estimates_prevent_mutation;
update public.soil_estimates set recorded_at = recorded_at - interval '11 minutes' where recorded_at is not null;
alter table public.soil_estimates enable trigger soil_estimates_prevent_mutation;
update public.alert_events set sent_at = now() - interval '11 minutes' where kind = 'estimate_entered';
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gNapkin'), 3, 'load', 'e3000000-0000-0000-0000-000000000004', pg_temp.ben())$$), '1',
  'more than 10 minutes after the batch started …');
select is((select count(*)::int from public.alert_events where kind = 'estimate_entered'), 3, '… a new batch, a new alert');

-- ══ rewash_added: a manager's rewash only ════════════════════════════════
select is(array[
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'bin', 'e4000000-0000-0000-0000-000000000001', pg_temp.id('gTowel'), p_is_rewash => true)$$),
  pg_temp.run_as('manager', $$select public.create_queue_item(pg_temp.id('wash'), 1, 'bin', 'e4000000-0000-0000-0000-000000000001', pg_temp.id('gTowel'), p_is_rewash => true)$$),
  pg_temp.run_as('owner',   $$select public.create_queue_item(pg_temp.id('wash'), 1, 'load', 'e4000000-0000-0000-0000-000000000002', pg_temp.id('gTowel'), p_is_rewash => true)$$),
  pg_temp.run_as('owner',   $$select public.create_queue_item(pg_temp.id('wash'), 2, 'load', 'e4000000-0000-0000-0000-000000000003', pg_temp.id('gNapkin'))$$)],
  '{1,1,1,1}', 'a manager adds a rewash (and retries it); an owner adds a rewash and normal work');
select is((select array_agg(q.client_id) from public.alert_events a join public.queue_items q on q.id = a.subject_id where a.kind = 'rewash_added'),
  array['e4000000-0000-0000-0000-000000000001'::uuid], 'one rewash_added alert: the manager''s (not the retry, not the owner''s own)');
select is((select app.alert_payload(a) - 'queue_item_id' - 'area_id' - 'created_at' - 'wash_group_id' from public.alert_events a where a.kind = 'rewash_added'),
  jsonb_build_object('area_name', 'Washroom', 'wash_group_name', 'Towels', 'wash_group_name_i18n', '{}'::jsonb, 'customer_id', null,
                     'qty', 1.00, 'unit', 'bin', 'qty_loads', null, 'status', 'queued'),
  'payload: area, group, qty + unit (+ loads; null without a bin factor), status; no names, no note');

-- ══ Starts write no off_queue_start alert (removed 2026-11-07) ══════════
-- Since 2026-11-09 the estimates above also queued Napkins and Towels "from estimates" items; they are
-- cancelled here so the queue order below is the one this section was written for.
update public.queue_items set status = 'cancelled' where from_estimate and status in ('queued', 'in_progress');
-- Queue now (normal items in creation order): the manager's Towels rewash (1 bin, no bin factor: never
-- auto-completes) is next for Washer 1; then the owner's Towels rewash; then Napkins (2 loads).
select is(array[
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e5000000-0000-0000-0000-000000000001')$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e5000000-0000-0000-0000-000000000002', p_wash_group_id => pg_temp.id('gMat'), p_off_queue_reason => 'other')$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e5000000-0000-0000-0000-000000000003',
                             p_queue_item_id => (select id from public.queue_items where client_id = 'e4000000-0000-0000-0000-000000000003'), p_off_queue_reason => 'other')$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e5000000-0000-0000-0000-000000000003',
                             p_queue_item_id => (select id from public.queue_items where client_id = 'e4000000-0000-0000-0000-000000000003'), p_off_queue_reason => 'other')$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e5000000-0000-0000-0000-000000000005',
                             p_queue_item_id => (select id from public.queue_items where client_id = 'e4000000-0000-0000-0000-000000000002'))$$)],
  '{1,1,1,1,1}', 'starts: the queue''s next item; an off-queue Mats load; Napkins picked out of order (and its retry); the other Towels item (same group as next)');
select is((select count(*)::int from public.alert_events where kind = 'off_queue_start'), 0,
  'no off_queue_start alert any more (owner 2026-11-07): not for the off-queue load, not for the out-of-order group');
select ok(not (app.owner_alert_kinds() @> '{off_queue_start}') and not (app.push_alert_kinds() @> '{off_queue_start}')
          and app.alert_level_default('off_queue_start') is null,
  'off_queue_start is in no kind list and has no default level');
update public.queue_items set status = 'cancelled' where status in ('queued', 'in_progress');
select is(pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e5000000-0000-0000-0000-000000000004', p_wash_group_id => pg_temp.id('gTowel'), p_confirm_running => true, p_off_queue_reason => 'other')$$), '1',
  'a start with nothing queued …');
select is((select count(*)::int from public.alert_events where kind = 'off_queue_start'), 0, '… and writes no alert either');

-- ══ Visibility, push and levels ══════════════════════════════════════════
select is(array[pg_temp.my('owner'), pg_temp.my('manager'), pg_temp.my('ownerP')],
  array['estimate_entered=2,rewash_added=1', '-', 'estimate_entered=3,rewash_added=1'],
  'quiet kinds show in the owners'' Alerts tab (never the batch an owner entered themselves, 2026-11-09); never managers''');
select is((select array_agg(distinct a.recipients::text) from public.alert_events a where a.kind in ('estimate_entered', 'off_queue_start')),
  array['{quiet}'], 'quiet for every owner: stored as delivered-with-nothing-to-send …');
select is((select count(*)::int from app.pending_push_notifications() p where p.kind in ('estimate_entered', 'rewash_added', 'off_queue_start')), 0,
  '… and never pushed (the owner, who has a phone subscribed, keeps them quiet)');
select is((select array_agg(u) from public.alert_events a cross join lateral app.alert_recipient_users(a) u where a.kind = 'rewash_added'),
  array[pg_temp.id('ownerP')], 'levels are per owner: ownerP set rewash_added to push, so only ownerP is a push recipient');
select ok(pg_temp.val_as('owner', $$select public.get_my_alert_count(pg_temp.id('plantA'))$$)::int >= 3, 'quiet alerts count in the badge');
select is(array[
  pg_temp.val_as('owner', $$select (public.set_alert_level(pg_temp.mid('owner'), 'estimate_entered', 'off')).alert_levels ->> 'estimate_entered'$$),
  pg_temp.my('owner')],
  array['off', 'rewash_added=1'], 'off hides the kind from that owner''s Alerts tab …');
select is(pg_temp.my('ownerP'), 'estimate_entered=3,rewash_added=1', '… only for that owner');
select is(pg_temp.run_as('owner', format($$select * from public.clear_my_alerts(pg_temp.id('plantA'), %L)$$,
                                         (select array_agg(a.id) from public.alert_events a where a.kind = 'estimate_entered'))),
  '0', 'an alert that is off for the caller cannot be cleared by them (not theirs)');
select is(pg_temp.val_as('owner', $$select (public.set_alert_level(pg_temp.mid('owner'), 'estimate_entered', 'push')).alert_levels ->> 'estimate_entered'$$),
  'push', 'the owner switches estimate_entered to push');
select is((select count(*)::int from app.pending_push_notifications() p where p.kind = 'estimate_entered'), 0,
  'switching to push never pushes old (quiet) alerts');
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gMat'), 1, 'load', 'e3000000-0000-0000-0000-000000000005', pg_temp.ben())$$), '1',
  'a new estimate (same manager, same batch window as #4) …');
-- Batches are anchored on the first estimate's recorded_at (2026-11-07): move both back in time.
alter table public.soil_estimates disable trigger soil_estimates_prevent_mutation;
update public.soil_estimates set recorded_at = recorded_at - interval '11 minutes' where recorded_at is not null;
alter table public.soil_estimates enable trigger soil_estimates_prevent_mutation;
update public.alert_events set sent_at = now() - interval '11 minutes' where kind = 'estimate_entered';
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gMat'), 2, 'load', 'e3000000-0000-0000-0000-000000000006', pg_temp.ben())$$), '1',
  '… and one in a new batch');
select is((select array_agg(p.user_id) from app.pending_push_notifications() p where p.kind = 'estimate_entered'), array[pg_temp.id('owner')],
  'push level: the new batch is pushed to that owner only (ownerP keeps quiet; managers never)');
select is(pg_temp.val_as('ownerP', $$select public.clear_my_finished_alerts(pg_temp.id('plantA'))$$), '5',
  'the new kinds are informational: "clear all finished" clears all 5 of ownerP''s (4 estimate batches, 1 rewash)');

select * from finish();
rollback;
