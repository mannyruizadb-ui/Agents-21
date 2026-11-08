-- Owner decision 2026-11-01: machines.load_factor (standard loads per load run; Washer 6 ≈ 1.19).
-- Unitless ratio, never a weight. Same writers as machines (owner/manager), audited.
-- Matrix arrays: [owner, manager, lead, viewer, display, display-without-device, owner of B, anon].
begin;
\ir _fixtures.psql
select plan(10);

select col_not_null('public', 'machines', 'load_factor', 'machines.load_factor is not null');
select col_type_is('public', 'machines', 'load_factor', 'numeric(4,2)', 'load_factor is numeric(4,2)');
select is((select load_factor from public.machines where id = pg_temp.id('machine')), 1.00::numeric, 'defaults to 1.00');
select is(array[pg_temp.run_as('owner', $$update public.machines set load_factor = 0.24 where id = pg_temp.id('machine')$$),
                pg_temp.run_as('owner', $$update public.machines set load_factor = 4.01 where id = pg_temp.id('machine')$$),
                pg_temp.run_as('owner', $$update public.machines set load_factor = -1 where id = pg_temp.id('machine')$$)],
  '{23514,23514,23514}', 'CHECK rejects factors outside 0.25–4.00');
select is(array[pg_temp.run_as('owner', $$update public.machines set load_factor = 0.25 where id = pg_temp.id('machine')$$),
                pg_temp.run_as('owner', $$update public.machines set load_factor = 4.00 where id = pg_temp.id('machine')$$)],
  '{1,1}', 'bounds 0.25 and 4.00 are accepted');
select is(pg_temp.reads($$select load_factor from public.machines where plant_id = pg_temp.id('plantA')$$),
  '{1,1,1,1,1,0,0,42501}', 'load_factor R like machines (display own plant; no cross-tenant)');
select is(pg_temp.writes($$update public.machines set load_factor = 1.19 where id = pg_temp.id('machine')$$),
  '{1,0,0,0,0,0,0,42501}', 'load_factor U: owner only (machines setup, owner 2026-11-05)');
select is(pg_temp.run_as('ownerB', $$update public.machines set load_factor = 2 where plant_id = pg_temp.id('plantA')$$),
  '0', 'another tenant cannot change plant A factors');
select is(pg_temp.writes($$insert into public.machines (org_id, plant_id, area_id, name, kind, load_factor)
  values (pg_temp.id('orgA'), pg_temp.id('plantA'), pg_temp.id('wash'), 'W-' || substr(md5(random()::text), 1, 6), 'washer', 1.19)$$),
  '{1,42501,42501,42501,42501,42501,42501,42501}', 'machines C with a factor: owner only');
select ok((select count(*) from public.audit_log where action = 'machines.update' and entity_id = pg_temp.id('machine')
            and before ->> 'load_factor' = '4.00' and after ->> 'load_factor' = '1.19') = 1,
  'a load_factor change is audited (before/after)');

select * from finish();
rollback;
