-- PlantBoard local/dev seed: ADB org, Miami plant, areas, languages, item catalog, shifts.
-- Sources: research/item-catalog.md (2026-10-27), research/shift-schedule.md (2026-10-30).
-- Only owner-confirmed values are filled in; TBD values stay null (never invented).
-- No entry_staff rows: the owner adds people and PINs in the app (A8).

-- ── Languages (H1) ────────────────────────────────────────────────────────
insert into public.languages (code, name_native, rtl, ui_ready) values
  ('en', 'English',        false, true),
  ('es', 'Español',        false, true),
  ('ht', 'Kreyòl ayisyen', false, false)
on conflict (code) do nothing;

-- ── Tenancy + layout (A1, A3) ─────────────────────────────────────────────
insert into public.organizations (name, slug)
values ('America''s Dust Busters', 'americas-dust-busters');

insert into public.plants (org_id, name, timezone, default_language, enabled_languages)
select o.id, 'Miami', 'America/New_York', 'en', '{en,es}'
  from public.organizations o where o.slug = 'americas-dust-busters';

insert into public.areas (org_id, plant_id, name, kind, sort_order)
select p.org_id, p.id, a.name, a.kind::app.area_kind, a.sort_order
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values ('Washroom', 'washroom', 10), ('Finishing', 'finishing', 20)) as a(name, kind, sort_order)
 where p.name = 'Miami';

-- ── Item catalog (A2): 35 items; the sanitizer dispenser is excluded (not washed or finished) ──
-- Spanish names are AI drafts from research/item-catalog.md, pending the separate AI review (H1).
-- Estimates: 'load' (catalog 🔸 assumed default); no basket factors yet. pieces_per_load: all TBD (null).
insert into public.item_types (org_id, plant_id, name, name_i18n, category, count_mode, pack_size, sort_order)
select p.org_id, p.id, i.name, jsonb_build_object('es', i.name_es), i.category::app.item_category,
       i.count_mode::app.count_mode, i.pack_size, i.sort_order
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
  -- Floor mats: by unit ✅
  ('3×5 mat',            'Tapete 3×5',            'mat',     'unit', null::int,  10),
  ('4×6 mat',            'Tapete 4×6',            'mat',     'unit', null,       20),
  ('3×10 mat',           'Tapete 3×10',           'mat',     'unit', null,       30),
  ('5×7 mat',            'Tapete 5×7',            'mat',     'unit', null,       40),
  ('Logo mat',           'Tapete con logo',       'mat',     'unit', null,       50),
  ('Elevator mat',       'Tapete de elevador',    'mat',     'unit', null,       60),
  -- Mops: by unit (🔸 assumed)
  ('Dust mop',           'Mopa de polvo',         'mop',     'unit', null,       70),
  ('Wet mop',            'Trapeador',             'mop',     'unit', null,       80),
  ('Microfiber mop',     'Mopa de microfibra',    'mop',     'unit', null,       90),
  -- Microfiber towel/wipe: pack of 50 ✅ (owner 2026-11-01)
  ('Microfiber wipe',    'Paño de microfibra',    'other',   'pack', 50,        100),
  -- Napkin: pack of 100 ✅
  ('Napkin',             'Servilleta',            'linen',   'pack', 100,       110),
  -- Tablecloths: pack sizes ✅; rounds by unit ✅ (owner 2026-11-01). Whites wash only with whites and
  -- blacks only with blacks, so each color is its own item.
  ('Tablecloth 42×42 white', 'Mantel 42×42 blanco', 'linen', 'pack', 25, 114),
  ('Tablecloth 52×52 white', 'Mantel 52×52 blanco', 'linen', 'pack', 20, 116),
  ('Tablecloth 62×62 white', 'Mantel 62×62 blanco', 'linen', 'pack', 15, 118),
  ('Tablecloth 72×72 white', 'Mantel 72×72 blanco', 'linen', 'pack', 10, 120),
  ('Tablecloth 90×90 white', 'Mantel 90×90 blanco', 'linen', 'pack', 5, 122),
  ('Tablecloth 52×114 white', 'Mantel 52×114 blanco', 'linen', 'pack', 10, 124),
  ('Tablecloth 120" round white', 'Mantel redondo 120 pulg. blanco', 'linen', 'unit', null, 126),
  ('Tablecloth 132" round white', 'Mantel redondo 132 pulg. blanco', 'linen', 'unit', null, 128),
  ('Tablecloth 42×42 black', 'Mantel 42×42 negro', 'linen', 'pack', 25, 130),
  ('Tablecloth 52×52 black', 'Mantel 52×52 negro', 'linen', 'pack', 20, 132),
  ('Tablecloth 62×62 black', 'Mantel 62×62 negro', 'linen', 'pack', 15, 134),
  ('Tablecloth 72×72 black', 'Mantel 72×72 negro', 'linen', 'pack', 10, 136),
  ('Tablecloth 90×90 black', 'Mantel 90×90 negro', 'linen', 'pack', 5, 138),
  ('Tablecloth 52×114 black', 'Mantel 52×114 negro', 'linen', 'pack', 10, 140),
  ('Tablecloth 120" round black', 'Mantel redondo 120 pulg. negro', 'linen', 'unit', null, 142),
  ('Tablecloth 132" round black', 'Mantel redondo 132 pulg. negro', 'linen', 'unit', null, 144),
  -- Kitchen towel: pack of 50 ✅ (owner 2026-11-01)
  ('Kitchen towel',      'Toalla de cocina',      'towel',   'pack', 50,        180),
  -- Apparel: apron, chef coat, uniform by unit (🔸 assumed); butcher coat by unit ✅
  ('Apron',              'Delantal',              'apparel', 'unit', null,      190),
  ('Chef coat',          'Filipina de chef',      'apparel', 'unit', null,      200),
  ('Butcher coat',       'Bata de carnicero',     'apparel', 'unit', null,      210),
  -- Sheets: all three grades in packs of 10 ✅ (owner 2026-11-01).
  ('Sheet – new',        'Sábana nueva',          'linen',   'pack', 10,        220),
  ('Sheet – regular',    'Sábana regular',        'linen',   'pack', 10,        230),
  ('Sheet – old',        'Sábana vieja',          'linen',   'pack', 10,        240),
  -- Uniform: one item (🔸 assumed; shirts/pants split pending)
  ('Uniform',            'Uniforme',              'apparel', 'unit', null,      250)
 ) as i(name, name_es, category, count_mode, pack_size, sort_order)
 where p.name = 'Miami';

-- ── Washroom machines (owner 2026-11-01): 3 TVs = washers 1–3, washers 4–6, dryers 1–4 ──
-- Rated size is a description only; PlantBoard never measures weight. Dryer models TBD (owner).
insert into public.machines (org_id, plant_id, area_id, name, kind, vendor, model)
select a.org_id, a.plant_id, a.id, m.name, m.kind::app.machine_kind, m.vendor, m.model
  from public.areas a
  join public.plants p on p.id = a.plant_id and p.name = 'Miami'
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
  ('Washer 1', 'washer', 'Milnor', '135 lb hard-mount'),
  ('Washer 2', 'washer', 'Milnor', '135 lb hard-mount'),
  ('Washer 3', 'washer', 'Milnor', '135 lb hard-mount'),
  ('Washer 4', 'washer', 'Milnor', '135 lb hard-mount'),
  ('Washer 5', 'washer', 'Milnor', '135 lb hard-mount'),
  ('Washer 6', 'washer', 'Milnor', '160 lb soft-mount'),
  ('Dryer 1',  'dryer',  null,     null),
  ('Dryer 2',  'dryer',  null,     null),
  ('Dryer 3',  'dryer',  null,     null),
  ('Dryer 4',  'dryer',  null,     null)
 ) as m(name, kind, vendor, model)
 where a.kind = 'washroom';

-- ── Shifts (A6), per area; days = the day a shift STARTS (0 = Sun … 6 = Sat) ──
-- Thursday variants are separate rows with the same name. No washroom midday shift (owner).
insert into public.shifts (org_id, plant_id, area_id, name, start_local, end_local, days_of_week)
select a.org_id, a.plant_id, a.id, s.name, s.start_local::time, s.end_local::time, s.days::smallint[]
  from public.areas a
  join public.plants p on p.id = a.plant_id and p.name = 'Miami'
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
  join (values
    ('Finishing', 'Evening', '16:00', '00:00', '{1,2,3,5,6}'),
    ('Finishing', 'Evening', '17:00', '00:00', '{4}'),
    ('Finishing', 'Night',   '00:00', '10:00', '{2,3,5,6}'),
    ('Finishing', 'Night',   '00:00', '05:00', '{4}'),         -- 🔸 Thu short night ("finish at like 5 a.m.")
    ('Finishing', 'Day',     '10:00', '16:00', '{2,3,5,6}'),
    ('Washroom',  'Evening', '14:00', '00:00', '{1,2,3,5,6}'),
    ('Washroom',  'Evening', '15:00', '00:00', '{4}'),
    ('Washroom',  'Night',   '00:00', '12:00', '{2,3,5,6}')
  ) as s(area_name, name, start_local, end_local, days) on s.area_name = a.name;

-- Local dev convenience: instances for the next 7 days (pg_cron does this daily in deployed envs).
select app.generate_shift_instances(p.id, 7)
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami';
