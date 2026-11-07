-- Owner information alerts and levels (owner 2026-11-06, C): estimate_entered (one per batch),
-- rewash_added (a manager's rewash), off_queue_start (a start that is not what the queue had next),
-- per-owner levels push | quiet | off (memberships.alert_levels, set_alert_level), quiet never pushed,
-- off hidden, all informational and clearable, no names in payloads.
begin;
\ir _fixtures.psql
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
  '{"customer_delivery":"push","estimate_entered":"quiet","rewash_added":"quiet","off_queue_start":"quiet"}'::jsonb,
  'defaults: customer_delivery push; estimate_entered, rewash_added, off_queue_start quiet');
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
  '{1,0,0,0,0,0,0,0}', 'alert_levels is readable where the membership is (an org-wide owner membership: org owners only)');

-- ══ set_alert_level ══════════════════════════════════════════════════════
select is(pg_temp.writes($$select public.set_alert_level(pg_temp.mid('owner'), 'rewash_added', 'quiet')$$),
  '{1,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,NOT_AUTHORIZED,42501}',
  'set_alert_level: owners only; managers, leads, viewers, displays, other tenants refused; anon cannot call');
select is(array[
  pg_temp.run_as('ownerP', $$select public.set_alert_level(pg_temp.mid('owner'), 'rewash_added', 'off')$$),
  pg_temp.run_as('owner',  $$select public.set_alert_level(pg_temp.mid('ownerP'), 'rewash_added', 'push')$$),
  pg_temp.run_as('owner',  $$select public.set_alert_level(gen_random_uuid(), 'rewash_added', 'push')$$),
  pg_temp.run_as('ownerB', $$select public.set_alert_level(pg_temp.mid('ownerP'), 'rewash_added', 'off')$$)],
  '{NOT_AUTHORIZED,1,NOT_AUTHORIZED,NOT_AUTHORIZED}',
  'an org-wide membership needs an org owner; an org owner sets a plant owner''s level; unknown and foreign ids: same NOT_AUTHORIZED');
select is(array[
  pg_temp.run_as('owner', $$select public.set_alert_level(pg_temp.mid('manager'), 'rewash_added', 'push')$$),
  pg_temp.run_as('owner', $$select public.set_alert_level(pg_temp.mid('owner'), 'machine_down', 'push')$$),
  pg_temp.run_as('owner', $$select public.set_alert_level(pg_temp.mid('owner'), 'rewash_added', 'loud')$$),
  pg_temp.run_as('owner', $$select public.set_alert_level(pg_temp.mid('owner'), null, 'push')$$),
  pg_temp.run_as('owner', $$select public.set_alert_level(pg_temp.mid('owner'), 'rewash_added', null)$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED}',
  'only owner memberships; only the four owner information kinds (existing kinds keep their switches); only push | quiet | off');
select is(pg_temp.val_as('owner', $$select (public.set_alert_level(pg_temp.mid('ownerP'), 'off_queue_start', 'off')).alert_levels ->> 'off_queue_start'$$),
  'off', 'returns the membership with the new level');
update public.memberships set revoked_at = now() where id = pg_temp.mid('ownerP');
select is(pg_temp.run_as('owner', $$select public.set_alert_level((select id from public.memberships where user_id = pg_temp.id('ownerP')), 'rewash_added', 'push')$$),
  'VALIDATION_FAILED', 'a revoked membership: VALIDATION_FAILED');
update public.memberships set revoked_at = null where user_id = pg_temp.id('ownerP');
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

-- ══ off_queue_start ══════════════════════════════════════════════════════
-- Queue now (normal items in creation order): the manager's Towels rewash (1 bin, no bin factor: never
-- auto-completes) is next for Washer 1; then the owner's Towels rewash; then Napkins (2 loads).
select is(array[
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e5000000-0000-0000-0000-000000000001')$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e5000000-0000-0000-0000-000000000002', p_wash_group_id => pg_temp.id('gMat'))$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e5000000-0000-0000-0000-000000000003',
                             p_queue_item_id => (select id from public.queue_items where client_id = 'e4000000-0000-0000-0000-000000000003'))$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e5000000-0000-0000-0000-000000000003',
                             p_queue_item_id => (select id from public.queue_items where client_id = 'e4000000-0000-0000-0000-000000000003'))$$),
  pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e5000000-0000-0000-0000-000000000005',
                             p_queue_item_id => (select id from public.queue_items where client_id = 'e4000000-0000-0000-0000-000000000002'))$$)],
  '{1,1,1,1,1}', 'starts: the queue''s next item; an off-queue Mats load; Napkins picked out of order (and its retry); the other Towels item (same group as next)');
select is((select array_agg(w.client_id::text || ':' || coalesce(a.dedupe_key, 'none') order by w.client_id)
             from public.alert_events a join public.washer_cycles w on w.id = a.subject_id where a.kind = 'off_queue_start'),
  array['e5000000-0000-0000-0000-000000000002:' || pg_temp.id('gTowel'), 'e5000000-0000-0000-0000-000000000003:' || pg_temp.id('gTowel')],
  'off_queue_start for the off-queue load and the out-of-order group (expected = Towels); none for the queue''s next item, a same-group item or the retry');
select is((select app.alert_payload(a) - 'cycle_id' - 'machine_id' - 'started_at' - 'wash_group_id' - 'expected_wash_group_id' - 'queue_item_id'
             from public.alert_events a join public.washer_cycles w on w.id = a.subject_id
            where a.kind = 'off_queue_start' and w.client_id = 'e5000000-0000-0000-0000-000000000002'),
  jsonb_build_object('machine_name', 'Washer 1', 'area_name', 'Washroom', 'wash_group_name', 'Mats', 'wash_group_name_i18n', '{}'::jsonb,
                     'customer_id', null, 'is_rewash', false, 'off_queue', true, 'expected_wash_group_name', 'Towels',
                     'expected_wash_group_name_i18n', '{}'::jsonb, 'voided', false),
  'payload: washer, group started, expected group, off_queue; no tapper');
update public.queue_items set status = 'cancelled' where status in ('queued', 'in_progress');
select is(pg_temp.run_as('lead', $$select public.start_washer_load(pg_temp.id('machine'), 'e5000000-0000-0000-0000-000000000004', p_wash_group_id => pg_temp.id('gTowel'), p_confirm_running => true)$$), '1',
  'a start with nothing queued …');
select is((select coalesce(a.dedupe_key, 'none') || ':' || (app.alert_payload(a) ->> 'off_queue') from public.alert_events a join public.washer_cycles w on w.id = a.subject_id
            where a.kind = 'off_queue_start' and w.client_id = 'e5000000-0000-0000-0000-000000000004'),
  'none:true', '… is an off-queue load (no expected group)');

-- ══ Visibility, push and levels ══════════════════════════════════════════
select is(array[pg_temp.my('owner'), pg_temp.my('manager'), pg_temp.my('ownerP')],
  array['estimate_entered=3,off_queue_start=3,rewash_added=1', '-', 'estimate_entered=3,rewash_added=1'],
  'quiet kinds show in the owners'' Alerts tab; never managers''; ownerP turned off_queue_start off');
select is((select array_agg(distinct a.recipients::text) from public.alert_events a where a.kind in ('estimate_entered', 'off_queue_start')),
  array['{quiet}'], 'quiet for every owner: stored as delivered-with-nothing-to-send …');
select is((select count(*)::int from app.pending_push_notifications() p where p.kind in ('estimate_entered', 'rewash_added', 'off_queue_start')), 0,
  '… and never pushed (the owner, who has a phone subscribed, keeps them quiet)');
select is((select array_agg(u) from public.alert_events a cross join lateral app.alert_recipient_users(a) u where a.kind = 'rewash_added'),
  array[pg_temp.id('ownerP')], 'levels are per owner: ownerP set rewash_added to push, so only ownerP is a push recipient');
select ok(pg_temp.val_as('owner', $$select public.get_my_alert_count(pg_temp.id('plantA'))$$)::int >= 7, 'quiet alerts count in the badge');
select is(array[
  pg_temp.val_as('owner', $$select (public.set_alert_level(pg_temp.mid('owner'), 'estimate_entered', 'off')).alert_levels ->> 'estimate_entered'$$),
  pg_temp.my('owner')],
  array['off', 'off_queue_start=3,rewash_added=1'], 'off hides the kind from that owner''s Alerts tab …');
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
update public.alert_events set sent_at = now() - interval '11 minutes' where kind = 'estimate_entered';
select is(pg_temp.run_as('manager', $$select public.record_soil_estimate(pg_temp.id('gMat'), 2, 'load', 'e3000000-0000-0000-0000-000000000006', pg_temp.ben())$$), '1',
  '… and one in a new batch');
select is((select array_agg(p.user_id) from app.pending_push_notifications() p where p.kind = 'estimate_entered'), array[pg_temp.id('owner')],
  'push level: the new batch is pushed to that owner only (ownerP keeps quiet; managers never)');
select is(pg_temp.val_as('ownerP', $$select public.clear_my_finished_alerts(pg_temp.id('plantA'))$$), '5',
  'the new kinds are informational: "clear all finished" clears all 5 of ownerP''s (4 estimate batches, 1 rewash)');

select * from finish();
rollback;
