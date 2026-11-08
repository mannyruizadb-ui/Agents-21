-- Spanish label of the soap machine-down reason (owner 2026-11-07): "Máquina de jabón" (was "Dispensador
-- de jabón"). The reason code stays soap_dispenser (machine_status_events point at it); only the label
-- changes, for existing plants (DATA, idempotent: only rows still carrying the old default label, so a label
-- the owner already edited in Setup is kept) and for new plants (the default-reasons trigger).

update public.machine_down_reasons r
   set label_i18n = r.label_i18n || '{"es": "Máquina de jabón"}'::jsonb
 where r.code = 'soap_dispenser'
   and r.label_i18n ->> 'es' = 'Dispensador de jabón';

create or replace function app.add_default_machine_down_reasons()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.machine_down_reasons (org_id, plant_id, code, label_i18n, sort_order, requires_details)
  select new.org_id, new.id, d.code, d.label, d.sort_order, d.code = 'other'
    from (values
      ('water_pump',     '{"en":"Water pump","es":"Bomba de agua"}'::jsonb,               10),
      ('soap_dispenser', '{"en":"Soap dispenser","es":"Máquina de jabón"}'::jsonb,        20),
      ('wont_start',     '{"en":"Won''t start","es":"No arranca"}'::jsonb,                30),
      ('leaking',        '{"en":"Leaking","es":"Gotea"}'::jsonb,                          40),
      ('other',          '{"en":"Other","es":"Otro"}'::jsonb,                             90)) as d(code, label, sort_order)
  on conflict (plant_id, code) do nothing;
  return null;
end;
$$;
comment on function app.add_default_machine_down_reasons() is
  'AFTER INSERT on plants: adds the 5 default machine-down reasons (water_pump, soap_dispenser, wont_start, leaking, other; en + es labels — soap_dispenser es "Máquina de jabón" since 2026-11-07; other requires details). Owner 2026-11-05.';
