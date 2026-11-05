-- Owner 2026-11-05: machines are set up in the app, by the OWNER, and the plant's other machines are
-- added so they can be marked down (and alert) like the washers.
--
-- 1. machines INSERT / UPDATE become owner-only (were owner/manager). Column grants are unchanged
--    (name, kind, area_id, vendor, model, external_ref, active, load_factor); kind/area stay fixed once
--    a machine has history (app.guard_setup_edit); every change is audited (machines_audit). No
--    deletes: deactivate instead. Managers keep reading machines and marking them down/up.
-- 2. DATA for the ADB plant (seed.sql carries the same for fresh databases), added only if a machine
--    with that name does not exist yet:
--      washroom  (utilities): Compressor, Soap machine, Boiler, Water pump  → kind utility
--      finishing:             Ironer (ironer), Folder (folder), Wrapping machine (wrapper)
--    The utilities serve the whole plant; they sit in the washroom area (the only plant-utility-like
--    area that exists). load_factor stays 1.00 (only washers use it).

drop policy machines_insert on public.machines;
drop policy machines_update on public.machines;
create policy machines_insert on public.machines for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner}')));
create policy machines_update on public.machines for update to authenticated
  using ((select app.has_role(plant_id, '{owner}')))
  with check ((select app.has_role(plant_id, '{owner}')));
comment on table public.machines is
  'Plant machines (washers, dryers, ironers, folders, wrappers, utilities). Owner-only setup in the app (insert / rename / move / deactivate; kind and area fixed once used); everyone with a role reads. Down/up through set_machine_status.';

insert into public.machines (org_id, plant_id, area_id, name, kind)
select p.org_id, p.id, a.id, v.name, v.kind::app.machine_kind
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
   ('Compressor',       'utility', 'washroom'),
   ('Soap machine',     'utility', 'washroom'),
   ('Boiler',           'utility', 'washroom'),
   ('Water pump',       'utility', 'washroom'),
   ('Ironer',           'ironer',  'finishing'),
   ('Folder',           'folder',  'finishing'),
   ('Wrapping machine', 'wrapper', 'finishing')) as v(name, kind, area_kind)
  join public.areas a on a.plant_id = p.id and a.kind = v.area_kind::app.area_kind
 where p.name = 'Miami'
   and not exists (select 1 from public.machines m where m.plant_id = p.id and m.name = v.name);
