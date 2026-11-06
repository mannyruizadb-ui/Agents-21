-- Owner 2026-11-05: closed on Christmas Day, New Year's Day and Thanksgiving Day only. Holidays are
-- plant data (plant_holidays) used by app.generate_shift_instances.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(14);

insert into public.plant_holidays (org_id, plant_id, name, month, day, weekday, nth) values
  (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Christmas Day', 12, 25, null, null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), 'New Year''s Day', 1, 1, null, null),
  (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Thanksgiving Day', 11, null, 4, 4);

select is(array[app.is_plant_closed(pg_temp.id('plantA'), '2026-12-25'), app.is_plant_closed(pg_temp.id('plantA'), '2027-01-01'),
                app.is_plant_closed(pg_temp.id('plantA'), '2026-11-26'), app.is_plant_closed(pg_temp.id('plantA'), '2030-11-28')],
  array[true, true, true, true], 'closed: Christmas, New Year''s Day, Thanksgiving 2026-11-26 and 2030-11-28 (4th Thursdays)');
select is(array[app.is_plant_closed(pg_temp.id('plantA'), '2026-11-19'), app.is_plant_closed(pg_temp.id('plantA'), '2026-11-27'),
                app.is_plant_closed(pg_temp.id('plantA'), '2026-12-24'), app.is_plant_closed(pg_temp.id('plantB'), '2026-12-25')],
  array[false, false, false, false], 'open: the 3rd Thursday, the day after Thanksgiving, Christmas Eve; plant B has no rules');
insert into public.plant_holidays (org_id, plant_id, name, month, weekday, nth) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Memorial Day (test)', 5, 1, -1);
select is(array[app.is_plant_closed(pg_temp.id('plantA'), '2027-05-31'), app.is_plant_closed(pg_temp.id('plantA'), '2027-05-24')],
  array[true, false], 'nth = -1 means the last weekday of the month');
update public.plant_holidays set active = false where name = 'Memorial Day (test)';
select is(app.is_plant_closed(pg_temp.id('plantA'), '2027-05-31'), false, 'an inactive rule does not close the plant');

-- ══ Generation skips holidays (far-future dates, so "future instance" holds whenever the test runs) ══
select ok(app.generate_shift_instances(pg_temp.id('plantA'), 7, '2030-11-25') > 0, 'generate Mon 2030-11-25 … Sun 2030-12-01');
select is((select count(*)::int from public.shift_instances where plant_id = pg_temp.id('plantA') and business_date = '2030-11-28'), 0,
  'no shift instance starts on Thanksgiving 2030-11-28');
select ok((select count(*) from public.shift_instances where plant_id = pg_temp.id('plantA') and business_date = '2030-11-27') > 0
          and (select count(*) from public.shift_instances where plant_id = pg_temp.id('plantA') and business_date = '2030-11-29') > 0,
  'the days around it are generated');
-- An instance generated before a rule existed is marked skipped (never deleted) by the next run.
select ok(app.generate_shift_instances(pg_temp.id('plantA'), 2, '2031-01-08') >= 0, 'generate 2031-01-08 … 09');
insert into public.plant_holidays (org_id, plant_id, name, month, day) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Test closure', 1, 8);
select ok(app.generate_shift_instances(pg_temp.id('plantA'), 2, '2031-01-08') > 0, 'regenerate after adding a rule for Jan 8');
select is((select count(*) filter (where skipped_at is null)::int from public.shift_instances where plant_id = pg_temp.id('plantA') and business_date = '2031-01-08'), 0,
  'the existing Jan 8 instances are now skipped');

-- ══ Access ═══════════════════════════════════════════════════════════════
select is(pg_temp.reads($$select 1 from public.plant_holidays where plant_id = pg_temp.id('plantA')$$), '{5,5,5,5,0,0,0,42501}',
  'reads: plant roles; display and other tenant none; anon no privilege');
select is(pg_temp.writes($$insert into public.plant_holidays (org_id, plant_id, name, month, day) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'H-' || substr(md5(random()::text), 1, 6), 7, 4)$$),
  '{1,42501,42501,42501,42501,42501,42501,42501}', 'add a holiday: owner only');
select is(array[
  pg_temp.as_service($$insert into public.plant_holidays (org_id, plant_id, name, month, day, weekday, nth) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Both', 7, 4, 4, 1)$$),
  pg_temp.as_service($$insert into public.plant_holidays (org_id, plant_id, name, month) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Neither', 7)$$),
  pg_temp.as_service($$insert into public.plant_holidays (org_id, plant_id, name, month, weekday, nth) values (pg_temp.id('orgA'), pg_temp.id('plantA'), 'Bad nth', 7, 4, 6)$$)],
  '{23514,23514,23514}', 'a rule is a fixed date OR an nth weekday (1..5 or -1)');

select is((select array_agg(h.name order by h.month desc, h.name) from public.plant_holidays h
             join public.plants p on p.id = h.plant_id and p.name = 'Miami' where h.active),
  array['Christmas Day', 'Thanksgiving Day', 'New Year''s Day'], 'ADB: closed on Christmas, Thanksgiving and New Year''s Day only');

select * from finish();
rollback;
