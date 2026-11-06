-- Owner 2026-11-05: machines are owner-only setup (add, rename, deactivate; audited); new kinds
-- wrapper and utility; the ADB plant's utilities and finishing machines; washer-only logic unchanged.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(10);

select enum_has_labels('app', 'machine_kind', array['washer','dryer','ironer','folder','wrapper','utility','other'],
  'machine kinds include wrapper and utility');
select is(pg_temp.writes($$insert into public.machines (org_id, plant_id, area_id, name, kind) values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'Boiler-' || substr(md5(random()::text), 1, 6), 'utility')$$),
  '{1,42501,42501,42501,42501,42501,42501,42501}', 'add a machine: owner only');
select is(pg_temp.writes($$update public.machines set name = 'Washer 1A' where id = pg_temp.id('machine')$$),
  '{1,0,0,0,0,0,0,0}', 'rename: owner only (others change no rows)');
select is(pg_temp.run_as('owner', $$update public.machines set active = false where kind = 'utility' and plant_id = pg_temp.id('plantA')$$),
  '1', 'deactivate: owner');
select is(pg_temp.run_as('owner', $$delete from public.machines where kind = 'utility'$$), '0', 'no deletes (no DELETE policy: deactivate instead)');
select is((select array_agg(action order by action) from public.audit_log where entity = 'machines' and plant_id = pg_temp.id('plantA')
             and actor_user_id = pg_temp.id('owner')),
  array['machines.insert', 'machines.update', 'machines.update'], 'every owner change is audited (insert, rename, deactivate)');
select is(pg_temp.run_as('manager', $$select public.set_machine_status((select id from public.machines where kind = 'utility' and plant_id = pg_temp.id('plantA')), 'down', gen_random_uuid(), p_reason_code => 'water_pump')$$),
  'VALIDATION_FAILED', 'an inactive utility cannot be marked down');
update public.machines set active = true where kind = 'utility';
select is(pg_temp.run_as('manager', $$select public.set_machine_status((select id from public.machines where kind = 'utility' and plant_id = pg_temp.id('plantA')), 'down', gen_random_uuid(), p_reason_code => 'water_pump')$$),
  '1', 'managers mark a utility down (alerts like a washer)');
select is(pg_temp.run_as('lead', $$select public.start_washer_load((select id from public.machines where kind = 'utility' and plant_id = pg_temp.id('plantA')), gen_random_uuid(), null, pg_temp.id('gMat'))$$),
  'VALIDATION_FAILED', 'only washers take start-taps');

-- The ADB seed (and the cloud data migration): utilities in the washroom, finishing machines in finishing.
select is((select array_agg(a.kind || ':' || m.name || ':' || m.kind order by a.kind, m.name)
             from public.machines m join public.areas a on a.id = m.area_id
             join public.plants p on p.id = m.plant_id and p.name = 'Miami'
            where m.kind in ('utility', 'ironer', 'folder', 'wrapper')),
  array['washroom:Boiler:utility', 'washroom:Compressor:utility', 'washroom:Soap machine:utility', 'washroom:Water pump:utility',
        'finishing:Folder:folder', 'finishing:Ironer:ironer', 'finishing:Wrapping machine:wrapper']::text[],
  'ADB machines added: compressor, soap machine, boiler, water pump; ironer, folder, wrapping machine');

select * from finish();
rollback;
