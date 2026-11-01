-- D3/B3/D4: display_messages (display: own area or all-areas), alert_events (service role only).
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(14);

insert into public.display_messages (id, org_id, plant_id, area_id, body, body_lang, body_i18n, severity, expires_at, created_by) values
  ('d1000000-0000-0000-0000-0000000000a1', pg_temp.id('orgA'), pg_temp.id('plantA'), null, 'Truck leaves 5:30', 'en', '{"es":"El camión sale 5:30"}', 'urgent', now() + interval '1 hour', pg_temp.id('manager')),
  ('d1000000-0000-0000-0000-0000000000a2', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Napkins first', 'en', '{}', 'info', now() + interval '1 hour', pg_temp.id('manager')),
  ('d1000000-0000-0000-0000-0000000000a3', pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), 'Mats first', 'en', '{}', 'info', now() + interval '1 hour', pg_temp.id('manager')),
  ('d1000000-0000-0000-0000-0000000000b1', pg_temp.id('orgB'), pg_temp.id('plantB'), null, 'B only', 'en', '{}', 'info', now() + interval '1 hour', pg_temp.id('ownerB'));

select is(pg_temp.reads($$select 1 from public.display_messages where plant_id = pg_temp.id('plantA')$$), '{3,3,3,3,2,0,0,0}',
  'display_messages R (display: own area + all-areas)');
select is(pg_temp.run_as('display', $$select 1 from public.display_messages where area_id = pg_temp.id('fin')$$, true), '0',
  'display cannot read another area''s message');
select is(pg_temp.writes($$insert into public.display_messages (org_id, plant_id, body, body_lang, expires_at, created_by)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Hola', 'es', now() + interval '1 hour', (select auth.uid()))$$),
  '{1,1,42501,42501,42501,42501,42501,42501}', 'display_messages C owner/manager');
select is(pg_temp.writes($$update public.display_messages set retracted_at = now() where id = 'd1000000-0000-0000-0000-0000000000a1'$$),
  '{1,1,0,0,0,0,0,0}', 'display_messages U (retract) owner/manager');
select is(pg_temp.run_as('manager', $$insert into public.display_messages (org_id, plant_id, body, body_lang, expires_at, created_by)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Bonjou', 'ht', now() + interval '1 hour', (select auth.uid()))$$),
  'VALIDATION_FAILED', 'message language must be enabled for the plant');
select is(pg_temp.run_as('manager', $$insert into public.display_messages (org_id, plant_id, body, body_lang, body_i18n, expires_at, created_by)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Hi', 'en', '{"xx":"?"}', now() + interval '1 hour', (select auth.uid()))$$),
  'VALIDATION_FAILED', 'translation keys must be enabled languages');
select is(pg_temp.run_as('manager', $$insert into public.display_messages (org_id, plant_id, body, body_lang, body_i18n, expires_at, created_by)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Hi', 'en', jsonb_build_object('es', repeat('x', 141)), now() + interval '1 hour', (select auth.uid()))$$),
  'VALIDATION_FAILED', 'message translations are ≤ 140 characters');
select is(pg_temp.run_as('manager', $$insert into public.display_messages (org_id, plant_id, body, body_lang, body_i18n, expires_at, created_by)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Hi', 'en', '{"es":"Hola"}', now() + interval '1 hour', (select auth.uid()))$$),
  '1', 'valid translation accepted');
select is(pg_temp.run_as('manager', $$insert into public.display_messages (org_id, plant_id, body, body_lang, expires_at, created_by)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Long', 'en', now() + interval '13 hours', (select auth.uid()))$$),
  '23514', 'messages expire within 12 hours');
select is(pg_temp.run_as('manager', $$insert into public.display_messages (org_id, plant_id, area_id, body, body_lang, expires_at, created_by)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('washB'), 'X', 'en', now() + interval '1 hour', (select auth.uid()))$$),
  '23503', 'message area must belong to the plant');

-- alert_events: no client access at all.
insert into public.alert_events (org_id, plant_id, kind, recipients) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'device_offline', '{owner@a.test}');
select is(pg_temp.reads($$select 1 from public.alert_events$$), '{0,0,0,0,0,0,0,0}', 'alert_events R denied (service role only)');
select is(pg_temp.writes($$insert into public.alert_events (org_id, plant_id, kind, recipients)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'import_failed', '{x@a.test}')$$),
  '{42501,42501,42501,42501,42501,42501,42501,42501}', 'alert_events C denied');
select throws_ok($$insert into public.alert_events (org_id, plant_id, kind, recipients) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'device_offline', '{}')$$,
  '23505', null, 'alerts dedupe per (kind, subject, shift)');
select throws_ok($$insert into public.alert_events (org_id, plant_id, kind, recipients) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'other', '{}')$$,
  '23514', null, 'alert kind CHECK');

select * from finish();
rollback;
