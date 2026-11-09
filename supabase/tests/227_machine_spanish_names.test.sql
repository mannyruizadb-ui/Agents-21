-- Spanish machine names (owner 2026-11-09, review item 10; 20261109215633_add_machine_spanish_names):
-- machines.name_i18n (owner-edited, language-checked, audited), the ADB data, get_machine_status and the
-- machine_down / washer_idle payloads carry it, and app.apply_machine_spanish_names never overwrites an edit.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(14);

create function pg_temp.adb() returns uuid language sql stable as $$
  select p.id from public.plants p
    join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
   where p.name = 'Miami';
$$;

-- ══ ADB data (seed ran the same function as the cloud migration) ═════════
select is((select array_agg(m.name || ' = ' || coalesce(m.name_i18n ->> 'es', '?') order by m.name) from public.machines m where m.plant_id = pg_temp.adb()),
  array['Boiler = Caldera', 'Compressor = Compresor', 'Dryer 1 = Secadora 1', 'Dryer 2 = Secadora 2', 'Dryer 3 = Secadora 3', 'Dryer 4 = Secadora 4',
        'Folder = Dobladora', 'Ironer = Planchadora', 'Soap machine = Máquina de jabón',
        'Washer 1 = Lavadora 1', 'Washer 2 = Lavadora 2', 'Washer 3 = Lavadora 3', 'Washer 4 = Lavadora 4', 'Washer 5 = Lavadora 5', 'Washer 6 = Lavadora 6',
        'Water pump = Bomba de agua', 'Wrapping machine = Empacadora'],
  'every ADB machine has its Spanish name');
select is(array[app.es_machine_name('  water   PUMP '), app.es_machine_name('Washer 12'), app.es_machine_name('dryer A'),
                coalesce(app.es_machine_name('Big ironer'), 'null'), coalesce(app.es_machine_name('Washer'), 'null')],
  array['Bomba de agua', 'Lavadora 12', 'Secadora A', 'null', 'null'], 'the mapping: case and spaces ignored; unknown names get none');

-- ══ Who edits name_i18n ══════════════════════════════════════════════════
select is(pg_temp.writes($$update public.machines set name_i18n = '{"es":"Lavadora uno"}' where id = pg_temp.id('machine')$$),
  '{1,0,0,0,0,0,0,42501}', 'name_i18n: the owner edits it; managers and everyone else change nothing (machines are owner setup)');
select is(pg_temp.run_as('owner', $$insert into public.machines (org_id, plant_id, area_id, name, kind, name_i18n)
                                    values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('fin'), 'Ironer 2', 'ironer', '{"es":"Planchadora 2"}')$$),
  '1', 'the owner adds a machine with its Spanish name');
select is(array[
  pg_temp.run_as('owner', $$update public.machines set name_i18n = '{"fr":"Lave-linge"}' where id = pg_temp.id('machine')$$),
  pg_temp.run_as('owner', $$update public.machines set name_i18n = '{"es":""}' where id = pg_temp.id('machine')$$),
  pg_temp.run_as('owner', $$update public.machines set name_i18n = jsonb_build_object('es', repeat('x', 61)) where id = pg_temp.id('machine')$$),
  pg_temp.run_as('owner', $$update public.machines set name_i18n = '{"es":5}' where id = pg_temp.id('machine')$$),
  pg_temp.run_as('owner', $$update public.machines set name_i18n = '"Lavadora"' where id = pg_temp.id('machine')$$),
  pg_temp.run_as('owner', $$update public.machines set name_i18n = null where id = pg_temp.id('machine')$$)],
  '{VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,VALIDATION_FAILED,22023,23502}',
  'enabled languages only; 1–60 characters; strings only; an object; never null');
select is(pg_temp.run_as('ownerB', $$update public.machines set name_i18n = '{"es":"x"}' where id = pg_temp.id('machine')$$), '0',
  'another tenant''s owner cannot rename plant A''s machine');
select is((select count(*)::int from public.audit_log a where a.entity = 'machines' and a.entity_id = pg_temp.id('machine')
             and a.actor_user_id = pg_temp.id('owner') and a.after -> 'name_i18n' ->> 'es' = 'Lavadora uno'), 1,
  'the edit is audited with the owner');

-- ══ Reads carry it ═══════════════════════════════════════════════════════
select is(array[pg_temp.val_as('lead', $$select machine_name_i18n ->> 'es' from public.get_machine_status(pg_temp.id('plantA')) where machine_id = pg_temp.id('machine')$$),
                pg_temp.val_as('owner', $$select machine_name_i18n::text from public.get_machine_status(pg_temp.id('plantA')) where machine_name = 'Ironer 2'$$)],
  array['Lavadora uno', '{"es": "Planchadora 2"}'], 'get_machine_status: machine_name_i18n for every role that reads it');
select is(array[pg_temp.run_as('display', $$select * from public.get_machine_status(pg_temp.id('plantA'))$$),
                pg_temp.run_as('ownerB', $$select * from public.get_machine_status(pg_temp.id('plantA'))$$),
                pg_temp.run_as('anon', $$select * from public.get_machine_status(pg_temp.id('plantA'))$$)],
  '{NOT_AUTHORIZED,NOT_AUTHORIZED,42501}', 'get_machine_status access is unchanged (displays, other tenants, anon refused)');
select is(pg_temp.run_as('manager', $$select public.set_machine_status(pg_temp.id('machine'), 'down', gen_random_uuid(), null, 'leaking')$$), '1',
  'Washer 1 goes down');
select is((select app.alert_payload(a) -> 'machine_name_i18n' ->> 'es' from public.alert_events a where a.kind = 'machine_down' and a.plant_id = pg_temp.id('plantA')),
  'Lavadora uno', 'the machine_down payload carries machine_name_i18n');
select is((select app.alert_payload(row(gen_random_uuid(), pg_temp.id('orgA'), pg_temp.id('plantA'), 'washer_idle', pg_temp.id('machine'), null, now(), '{}', null)::public.alert_events)
                  -> 'machine_name_i18n' ->> 'es'),
  'Lavadora uno', '… and so does the washer_idle payload');

-- ══ The data function ════════════════════════════════════════════════════
update public.machines set name_i18n = '{"es":"Caldera grande"}' where plant_id = pg_temp.adb() and name = 'Boiler';
update public.machines set name_i18n = '{}' where plant_id = pg_temp.adb() and name = 'Folder';
select is(app.apply_machine_spanish_names(pg_temp.adb()) - 'without_es', '{"named": 1}'::jsonb,
  're-running names only the machine left without es (idempotent otherwise)');
select is((select array_agg(m.name_i18n ->> 'es' order by m.name) from public.machines m where m.plant_id = pg_temp.adb() and m.name in ('Boiler', 'Folder')),
  array['Caldera grande', 'Dobladora'], 'an owner''s own Spanish name is never overwritten');

select * from finish();
rollback;
