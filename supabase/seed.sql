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

-- ── Item catalog (A2): 25 items; the sanitizer dispenser is excluded (not washed or finished) ──
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
  -- TODO owner: pack size (pack item assumed 🔸, not confirmed): counted by unit until then.
  ('Microfiber wipe',    'Paño de microfibra',    'other',   'unit', null,      100),
  -- Napkin: pack of 100 ✅
  ('Napkin',             'Servilleta',            'linen',   'pack', 100,       110),
  -- TODO owner: pack size (confirmed pack item) for each tablecloth: counted by unit until then.
  ('Tablecloth 52"',     'Mantel 52 pulg.',       'linen',   'unit', null,      120),
  ('Tablecloth 62"',     'Mantel 62 pulg.',       'linen',   'unit', null,      130),
  ('Tablecloth 72"',     'Mantel 72 pulg.',       'linen',   'unit', null,      140),
  ('Tablecloth 90"',     'Mantel 90 pulg.',       'linen',   'unit', null,      150),
  ('Tablecloth 120"',    'Mantel 120 pulg.',      'linen',   'unit', null,      160),
  ('Tablecloth 130"',    'Mantel 130 pulg.',      'linen',   'unit', null,      170),
  -- TODO owner: pack size (confirmed pack item): counted by unit until then.
  ('Kitchen towel',      'Toalla de cocina',      'towel',   'unit', null,      180),
  -- Apparel: apron, chef coat, uniform by unit (🔸 assumed); butcher coat by unit ✅
  ('Apron',              'Delantal',              'apparel', 'unit', null,      190),
  ('Chef coat',          'Filipina de chef',      'apparel', 'unit', null,      200),
  ('Butcher coat',       'Bata de carnicero',     'apparel', 'unit', null,      210),
  -- TODO owner: count mode / pack size for sheets (and whether new/regular/old are separate stock).
  ('Sheet – new',        'Sábana nueva',          'linen',   'unit', null,      220),
  ('Sheet – regular',    'Sábana regular',        'linen',   'unit', null,      230),
  ('Sheet – old',        'Sábana vieja',          'linen',   'unit', null,      240),
  -- Uniform: one item (🔸 assumed; shirts/pants split pending)
  ('Uniform',            'Uniforme',              'apparel', 'unit', null,      250)
 ) as i(name, name_es, category, count_mode, pack_size, sort_order)
 where p.name = 'Miami';

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
