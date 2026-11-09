-- PlantBoard local/dev seed: ADB org, Miami plant, areas, languages, wash formulas, wash groups + item catalog,
-- machines, shifts.
-- Sources: research/item-catalog.md (2026-10-27), research/shift-schedule.md (2026-10-30), owner decisions
-- 2026-11-01 and 2026-11-02.
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

-- A confirmed PIN is good for 10 minutes (owner 2026-11-04; data migration 20261104195456 for the cloud).
insert into public.plants (org_id, name, timezone, default_language, enabled_languages, staff_pin_reuse_minutes)
select o.id, 'Miami', 'America/New_York', 'en', '{en,es}', 10
  from public.organizations o where o.slug = 'americas-dust-busters';

insert into public.areas (org_id, plant_id, name, kind, sort_order)
select p.org_id, p.id, a.name, a.kind::app.area_kind, a.sort_order
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values ('Washroom', 'washroom', 10), ('Finishing', 'finishing', 20)) as a(name, kind, sort_order)
 where p.name = 'Miami';

-- ── Wash formulas (owner 2026-11-02): the 6 Milnor washer programs and their run times ──
-- One formula washes MANY wash groups, so the mapping is wash_groups.wash_formula_id (group → formula).
-- wash_formulas.wash_group_id (Accu-Flow resolution) is set only for a formula that washes exactly one
-- group; every formula here washes several, so it stays null.
insert into public.wash_formulas (org_id, plant_id, external_no, name, cycle_minutes)
select p.org_id, p.id, f.external_no, f.name, f.cycle_minutes
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
  ('1', 'Standard mats, dust mops',             26),
  ('2', 'Sheets, microfiber towels',            42),
  ('3', 'White napkins, tablecloths, coats',    88),
  ('4', 'Colored linen, black aprons',          59),
  ('5', 'Kitchen towels, white aprons, rewash', 96),
  ('6', 'Logo mats',                            26)
 ) as f(external_no, name, cycle_minutes)
 where p.name = 'Miami';

-- ── Wash groups + item catalog (A2; owner 2026-11-01, 2026-11-02): 33 groups, 73 items ──
-- Mats: regrouped into 4 basket groups at the end of this file (owner 2026-11-09; app.apply_mat_basket_groups).
-- The washroom works by WASH GROUP (what may share a washer); finishing counts ITEMS. Every item is in
-- exactly one group. Spanish names are AI drafts, pending the separate AI review (H1).
-- Estimates: 'load' by default; container factors and chip colors are set below (owner 2026-11-04).
-- pieces_per_load = pieces of the item in one full load of only that item in a standard washer
-- (load_factor 1.00). Mats only, from
-- the owner (2026-11-01), source 'counted' (the owner's own count, not derived from history):
--   3×5 = 16, 4×6 = 12, 3×10 = 9  ("16 3x5s in a washer, or 12 4x6s, or 9 3x10s");
--   5×7 = 3.5  (approximate, owner range midpoint: "about 3 or 4 5x7s to the washer");
--   2×3 = 35   (approximate, owner range midpoint: "probably 30 to 40"; low volume, ≤ ~10 a night).
-- Every other item: null (TODO owner). The sanitizer dispenser is excluded (not washed or finished).
-- formula_no = the washer program the group is washed with (owner 2026-11-02). Every group has one.
insert into public.wash_groups (org_id, plant_id, name, name_i18n, sort_order, wash_formula_id)
select p.org_id, p.id, g.name, jsonb_build_object('es', g.name_es), g.sort_order, f.id
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
  -- F1 standard mats + dust mops · F2 sheets + microfiber towels · F3 white linen + coats · F4 colored linen +
  -- black aprons · F5 kitchen towels + white aprons (+ rewash) · F6 logo mats (owner 2026-11-02).
  ('Black mats',                          'Tapetes negros',                            10, '1'),
  ('Colored mats',                        'Tapetes de color',                          20, '1'),   -- red, green, brown wash together
  ('Charcoal mats',                       'Tapetes carbón',                            30, '1'),   -- washed alone
  ('Scraper mats',                        'Tapetes raspadores',                        32, '1'),   -- washed alone (owner 2026-11-02)
  ('City & Brito mats',                   'Tapetes City y Brito',                      34, '1'),   -- wash together; the roller separates them
  ('Presidente logo mats',                'Tapetes con logo Presidente',               40, '6'),
  ('Logo mats',                           'Tapetes con logo',                          50, '6'),   -- all other logos
  ('Dust & wet mops',                     'Mapos de polvo y trapeadores',              60, '1'),
  ('Microfiber mops',                     'Mapos de microfibra',                       70, '1'),
  ('Kitchen towels',                      'Toallas de cocina',                         80, '5'),
  ('Microfiber towels',                   'Toallas de microfibra',                     90, '2'),   -- color and black wash together (owner 2026-11-02)
  ('Mechanic towels',                     'Toallas de mecánico',                       95, '5'),   -- white and colored wash together
  ('White aprons',                        'Delantales blancos',                       100, '5'),
  ('Black aprons',                        'Delantales negros',                        110, '4'),
  ('Coats (white)',                       'Batas y filipinas (blancas)',              120, '3'),
  ('White tablecloths',                   'Manteles blancos',                         130, '3'),
  ('Black tablecloths',                   'Manteles negros',                          140, '4'),
  ('Red & blue tablecloths',              'Manteles rojos y azules',                  145, '4'),   -- red and blue wash together (owner 2026-11-02)
  -- Napkins: each color washes on its own (owner 2026-11-01), except bone + chambray, which wash together
  -- on formula 3 (owner 2026-11-02; LinenTrack's "Charcoal Napkin" is chambray). Whites → F3, colors → F4.
  ('Napkins – Green & Red',               'Servilletas – verde y roja',               150, '4'),   -- green and red wash together (owner 2026-11-02)
  ('Napkins – Navy Blue w/ Stripe',       'Servilletas – azul marino con raya',       160, '4'),
  ('Napkins – Dark Navy Blue w/ Stripe',  'Servilletas – azul marino oscuro con raya', 170, '4'),
  ('Napkins – Navy Blue',                 'Servilletas – azul marino',                180, '4'),
  ('Napkins – Regular White',             'Servilletas – blanca regular',             210, '3'),
  ('Napkins – New White',                 'Servilletas – blanca nueva',               220, '3'),
  ('Napkins – Bone & Chambray',           'Servilletas – hueso y chambray',           230, '3'),
  ('Napkins – Black w/ Stripe',           'Servilletas – negra con raya',             240, '4'),
  ('Napkins – Black',                     'Servilletas – negra',                      250, '4'),
  ('Napkins – Pink',                      'Servilletas – rosada',                     260, '4'),
  ('Napkins – Cotton White',              'Servilletas – blanca de algodón',          270, '3'),
  ('Napkins – Cotton Black',              'Servilletas – negra de algodón',           280, '4'),
  ('Old sheets',                          'Sábanas viejas',                           290, '2'),
  ('Regular sheets',                      'Sábanas regulares',                        300, '2'),
  ('New sheets',                          'Sábanas nuevas',                           310, '2')
 ) as g(name, name_es, sort_order, formula_no)
  left join public.wash_formulas f on f.plant_id = p.id and f.external_no = g.formula_no
 where p.name = 'Miami';

-- Next-morning goods (owner confirmed 2026-11-02, research/washroom-patterns.md): floor mats, sheets and
-- butcher coats are processed the same night and ship on the 06:00 trucks. Nothing else does.
-- Mops are not floor mats, so they stay false.
update public.wash_groups g
   set ships_next_morning = true
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where g.plant_id = p.id and p.name = 'Miami'
   and g.name in ('Black mats', 'Colored mats', 'Charcoal mats', 'Scraper mats', 'City & Brito mats',
                  'Presidente logo mats', 'Logo mats', 'Old sheets', 'Regular sheets', 'New sheets',
                  'Coats (white)');

-- Container factors and chip colors (owner 2026-11-04, round 3; same values as the data migration
-- 20261104163718_set_wash_group_factors_and_colors.sql, which reaches the cloud). Loads per FULL
-- container, approximate: mats 3.5 per basket and 4 per bin (owner 2026-11-05); Kitchen towels 2 per basket, 2.5 per bin; sheets,
-- napkins and tablecloths 2 per bin; everything else null (TODO owner). Colors follow the goods' color.
with v(name, color_hex, loads_per_basket, loads_per_bin) as (values
  ('Black mats',                          '#1F1F1F', 3.5::numeric, 4::numeric),
  ('Colored mats',                        '#B45309', 3.5, 4),
  ('Charcoal mats',                       '#52525B', 3.5, 4),
  ('Scraper mats',                        '#7C5A3C', 3.5, 4),
  ('City & Brito mats',                   '#0F766E', 3.5, 4),
  ('Presidente logo mats',                '#7C3AED', 3.5, 4),
  ('Logo mats',                           '#C026D3', 3.5, 4),
  ('Dust & wet mops',                     '#78716C', null, null),
  ('Microfiber mops',                     '#0891B2', null, null),
  ('Kitchen towels',                      '#EA580C', 2,    2.5),
  ('Microfiber towels',                   '#6366F1', null, null),
  ('Mechanic towels',                     '#65A30D', null, null),
  ('White aprons',                        '#F8FAFC', null, null),
  ('Black aprons',                        '#3F3F46', null, null),
  ('Coats (white)',                       '#E2E8F0', null, null),
  ('White tablecloths',                   '#FFFFFF', null, 2),
  ('Black tablecloths',                   '#18181B', null, 2),
  ('Red & blue tablecloths',              '#DC2626', null, 2),
  ('Napkins – Green & Red',               '#16A34A', null, 2),
  ('Napkins – Navy Blue w/ Stripe',       '#1D4ED8', null, 2),
  ('Napkins – Dark Navy Blue w/ Stripe',  '#172554', null, 2),
  ('Napkins – Navy Blue',                 '#1E3A8A', null, 2),
  ('Napkins – Regular White',             '#F1F5F9', null, 2),
  ('Napkins – New White',                 '#F4F4F5', null, 2),
  ('Napkins – Bone & Chambray',           '#E7DCC4', null, 2),
  ('Napkins – Black w/ Stripe',           '#27272A', null, 2),
  ('Napkins – Black',                     '#0A0A0A', null, 2),
  ('Napkins – Pink',                      '#DB2777', null, 2),
  ('Napkins – Cotton White',              '#FAF7F0', null, 2),
  ('Napkins – Cotton Black',              '#2E2E2E', null, 2),
  ('Old sheets',                          '#CBD5E1', null, 2),
  ('Regular sheets',                      '#DBEAFE', null, 2),
  ('New sheets',                          '#F0F9FF', null, 2)
)
update public.wash_groups g
   set color_hex              = case when g.color_hex = '#64748B' then v.color_hex else g.color_hex end,
       loads_per_basket       = coalesce(g.loads_per_basket, v.loads_per_basket),
       loads_per_bin          = coalesce(g.loads_per_bin, v.loads_per_bin),
       allow_basket_estimates = g.allow_basket_estimates or (g.loads_per_basket is null and v.loads_per_basket is not null),
       allow_bin_estimates    = g.allow_bin_estimates or (g.loads_per_bin is null and v.loads_per_bin is not null)
  from v, public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where g.plant_id = p.id and p.name = 'Miami' and g.name = v.name
   and (g.color_hex = '#64748B'
        or (g.loads_per_basket is null and v.loads_per_basket is not null)
        or (g.loads_per_bin is null and v.loads_per_bin is not null));

insert into public.item_types (org_id, plant_id, wash_group_id, name, name_i18n, category, count_mode, pack_size,
                               pieces_per_load, pieces_per_load_source, sort_order)
select p.org_id, p.id, g.id, i.name, jsonb_build_object('es', i.name_es), i.category::app.item_category,
       i.count_mode::app.count_mode, i.pack_size, i.pieces_per_load,
       case when i.pieces_per_load is not null then 'counted' end, i.sort_order
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
  -- Black mats: by unit ✅
  ('Black mats', 'Black mat 2×3',  'Tapete negro 2×3',  'mat', 'unit', null::int, 35::numeric,   10),
  ('Black mats', 'Black mat 3×5',  'Tapete negro 3×5',  'mat', 'unit', null,      16,           20),
  ('Black mats', 'Black mat 4×6',  'Tapete negro 4×6',  'mat', 'unit', null,      12,           30),
  ('Black mats', 'Black mat 3×10', 'Tapete negro 3×10', 'mat', 'unit', null,       9,           40),
  ('Black mats', 'Black mat 5×7',  'Tapete negro 5×7',  'mat', 'unit', null,      3.5,          50),
  -- Colored mats (red, green, brown). 2×3 colored = red only (owner). No 3×4 item: the few red 3×4s are
  -- counted as red 3×5 (owner 2026-11-02).
  ('Colored mats', 'Colored mat 2×3',  'Tapete de color 2×3',  'mat', 'unit', null, 35,    60),
  ('Colored mats', 'Colored mat 3×5',  'Tapete de color 3×5',  'mat', 'unit', null, 16,    70),
  ('Colored mats', 'Colored mat 4×6',  'Tapete de color 4×6',  'mat', 'unit', null, 12,    80),
  ('Colored mats', 'Colored mat 3×10', 'Tapete de color 3×10', 'mat', 'unit', null,  9,    90),
  ('Colored mats', 'Colored mat 5×7',  'Tapete de color 5×7',  'mat', 'unit', null, 3.5,  100),
  -- Charcoal mats (washed alone)
  ('Charcoal mats', 'Charcoal mat 4×6', 'Tapete carbón 4×6', 'mat', 'unit', null, 12, 110),
  -- Scraper mats (washed alone) and City & Brito mats (wash together), from LinenTrack's list (owner 2026-11-02)
  ('Scraper mats',      'Scraper mat 3×5',     'Tapete raspador 3×5',  'mat', 'unit', null, 16, 115),
  ('City & Brito mats', 'Black City mat 3×5',  'Tapete City negro 3×5',  'mat', 'unit', null, 16, 116),
  ('City & Brito mats', 'Black City mat 4×6',  'Tapete City negro 4×6',  'mat', 'unit', null, 12, 118),
  ('City & Brito mats', 'Black City mat 3×10', 'Tapete City negro 3×10', 'mat', 'unit', null,  9, 120),
  ('City & Brito mats', 'Red Brito mat 4×6',   'Tapete Brito rojo 4×6',  'mat', 'unit', null, 12, 122),
  ('City & Brito mats', 'Red Brito mat 3×10',  'Tapete Brito rojo 3×10', 'mat', 'unit', null,  9, 124),
  -- Presidente logo mats: 5×7 only (owner 2026-11-01)
  ('Presidente logo mats', 'Presidente logo mat 5×7', 'Tapete con logo Presidente 5×7', 'mat', 'unit', null, 3.5, 140),
  -- Logo mats (all other logos)
  ('Logo mats', 'Logo mat 3×5', 'Tapete con logo 3×5', 'mat', 'unit', null, 16,   150),
  ('Logo mats', 'Logo mat 4×6', 'Tapete con logo 4×6', 'mat', 'unit', null, 12,   160),
  ('Logo mats', 'Logo mat 5×7', 'Tapete con logo 5×7', 'mat', 'unit', null, 3.5,  170),
  -- Mops: by unit (🔸 assumed)
  ('Dust & wet mops', 'Dust mop',       'Mopa de polvo',      'mop', 'unit', null, null, 180),
  ('Dust & wet mops', 'Wet mop',        'Trapeador',          'mop', 'unit', null, null, 190),
  ('Microfiber mops', 'Microfiber mop', 'Mopa de microfibra', 'mop', 'unit', null, null, 200),
  -- Kitchen towel: pack of 50 ✅ (owner 2026-11-01). Microfiber towels, color and black, pack of 50 ✅
  -- (owner 2026-11-02; they replace the old "microfiber wipe").
  ('Kitchen towels',    'Kitchen towel',            'Toalla de cocina',              'towel', 'pack', 50, null, 210),
  ('Microfiber towels', 'Microfiber towel – color', 'Toalla de microfibra – color',  'towel', 'pack', 50, null, 220),
  ('Microfiber towels', 'Microfiber towel – black', 'Toalla de microfibra – negra',  'towel', 'pack', 50, null, 222),
  -- Mechanic towels: white and colored wash together but are counted separately at finishing, pack of 100
  -- each ✅ (owner 2026-11-02).
  ('Mechanic towels',   'Mechanic towel – white',   'Toalla de mecánico – blanca',   'towel', 'pack', 100, null, 224),
  ('Mechanic towels',   'Mechanic towel – color',   'Toalla de mecánico – de color', 'towel', 'pack', 100, null, 226),
  -- Apparel: by unit (aprons, chef coat 🔸 assumed; butcher coats ✅ counted by size, owner 2026-11-02).
  -- White and black aprons always wash separately (owner), hence two groups.
  ('White aprons',  'Apron white',  'Delantal blanco',   'apparel', 'unit', null, null, 230),
  ('Black aprons',  'Apron black',  'Delantal negro',    'apparel', 'unit', null, null, 240),
  ('Coats (white)', 'Chef coat',    'Filipina de chef',  'apparel', 'unit', null, null, 250),
  ('Coats (white)', 'Butcher coat M',  'Bata de carnicero M',  'apparel', 'unit', null, null, 260),
  ('Coats (white)', 'Butcher coat L',  'Bata de carnicero L',  'apparel', 'unit', null, null, 262),
  ('Coats (white)', 'Butcher coat XL', 'Bata de carnicero XL', 'apparel', 'unit', null, null, 264),
  -- Tablecloths: pack sizes ✅; rounds by unit ✅ (owner 2026-11-01). Whites wash only with whites.
  ('White tablecloths', 'Tablecloth 42×42 white',      'Mantel 42×42 blanco',             'linen', 'pack', 25,   null, 270),
  ('White tablecloths', 'Tablecloth 52×52 white',      'Mantel 52×52 blanco',             'linen', 'pack', 20,   null, 280),
  ('White tablecloths', 'Tablecloth 62×62 white',      'Mantel 62×62 blanco',             'linen', 'pack', 15,   null, 290),
  ('White tablecloths', 'Tablecloth 72×72 white',      'Mantel 72×72 blanco',             'linen', 'pack', 10,   null, 300),
  ('White tablecloths', 'Tablecloth 90×90 white',      'Mantel 90×90 blanco',             'linen', 'pack', 5,    null, 310),
  ('White tablecloths', 'Tablecloth 52×114 white',     'Mantel 52×114 blanco',            'linen', 'pack', 10,   null, 320),
  ('White tablecloths', 'Tablecloth 120" round white', 'Mantel redondo 120 pulg. blanco', 'linen', 'unit', null, null, 330),
  ('White tablecloths', 'Tablecloth 132" round white', 'Mantel redondo 132 pulg. blanco', 'linen', 'unit', null, null, 340),
  -- Bone goes in the white wash (owner 2026-11-02). Pack 15 ✅ (owner-confirmed 2026-11-02).
  ('White tablecloths', 'Tablecloth 62×62 bone',       'Mantel 62×62 hueso',              'linen', 'pack', 15,   null, 345),
  -- Blacks wash only with blacks.
  ('Black tablecloths', 'Tablecloth 42×42 black',      'Mantel 42×42 negro',              'linen', 'pack', 25,   null, 350),
  ('Black tablecloths', 'Tablecloth 52×52 black',      'Mantel 52×52 negro',              'linen', 'pack', 20,   null, 360),
  ('Black tablecloths', 'Tablecloth 62×62 black',      'Mantel 62×62 negro',              'linen', 'pack', 15,   null, 370),
  ('Black tablecloths', 'Tablecloth 72×72 black',      'Mantel 72×72 negro',              'linen', 'pack', 10,   null, 380),
  ('Black tablecloths', 'Tablecloth 90×90 black',      'Mantel 90×90 negro',              'linen', 'pack', 5,    null, 390),
  ('Black tablecloths', 'Tablecloth 52×114 black',     'Mantel 52×114 negro',             'linen', 'pack', 10,   null, 400),
  ('Black tablecloths', 'Tablecloth 120" round black', 'Mantel redondo 120 pulg. negro',  'linen', 'unit', null, null, 410),
  ('Black tablecloths', 'Tablecloth 132" round black', 'Mantel redondo 132 pulg. negro',  'linen', 'unit', null, null, 420),
  -- Red and blue wash together (owner 2026-11-02). Pack sizes ✅ (owner-confirmed 2026-11-02).
  ('Red & blue tablecloths', 'Tablecloth 62×62 red',  'Mantel 62×62 rojo', 'linen', 'pack', 15, null, 422),
  ('Red & blue tablecloths', 'Tablecloth 72×72 red',  'Mantel 72×72 rojo', 'linen', 'pack', 10, null, 424),
  ('Red & blue tablecloths', 'Tablecloth 90×90 red',  'Mantel 90×90 rojo', 'linen', 'pack', 5,  null, 426),
  ('Red & blue tablecloths', 'Tablecloth 62×62 blue', 'Mantel 62×62 azul', 'linen', 'pack', 15, null, 428),
  -- Napkins: one item per color; each color is its own group except bone + chambray (one group). Pack of 100 for every color and material ✅
  -- (owner 2026-11-01).
  ('Napkins – Green & Red',              'Napkin – Green',                    'Servilleta – verde',                       'linen', 'pack', 100, null, 430),
  ('Napkins – Navy Blue w/ Stripe',      'Napkin – Navy Blue w/ Stripe',      'Servilleta – azul marino con raya',        'linen', 'pack', 100, null, 440),
  ('Napkins – Dark Navy Blue w/ Stripe', 'Napkin – Dark Navy Blue w/ Stripe', 'Servilleta – azul marino oscuro con raya', 'linen', 'pack', 100, null, 450),
  ('Napkins – Navy Blue',                'Napkin – Navy Blue',                'Servilleta – azul marino',                 'linen', 'pack', 100, null, 460),
  ('Napkins – Bone & Chambray',          'Napkin – Bone',                     'Servilleta – hueso',                       'linen', 'pack', 100, null, 470),
  ('Napkins – Green & Red',              'Napkin – Red',                      'Servilleta – roja',                        'linen', 'pack', 100, null, 480),
  ('Napkins – Regular White',            'Napkin – Regular White',            'Servilleta – blanca regular',              'linen', 'pack', 100, null, 490),
  ('Napkins – New White',                'Napkin – New White',                'Servilleta – blanca nueva',                'linen', 'pack', 100, null, 500),
  ('Napkins – Bone & Chambray',          'Napkin – Chambray',                 'Servilleta – chambray',                    'linen', 'pack', 100, null, 510),
  ('Napkins – Black w/ Stripe',          'Napkin – Black w/ Stripe',          'Servilleta – negra con raya',              'linen', 'pack', 100, null, 520),
  ('Napkins – Black',                    'Napkin – Black',                    'Servilleta – negra',                       'linen', 'pack', 100, null, 530),
  ('Napkins – Pink',                     'Napkin – Pink',                     'Servilleta – rosada',                      'linen', 'pack', 100, null, 540),
  ('Napkins – Cotton White',             'Napkin – Cotton White',             'Servilleta – blanca de algodón',           'linen', 'pack', 100, null, 550),
  ('Napkins – Cotton Black',             'Napkin – Cotton Black',             'Servilleta – negra de algodón',            'linen', 'pack', 100, null, 560),
  -- Sheets: all three grades in packs of 10 ✅ (owner 2026-11-01); each grade washes on its own.
  ('Old sheets',     'Sheet – old',     'Sábana vieja',   'linen', 'pack', 10, null, 570),
  ('Regular sheets', 'Sheet – regular', 'Sábana regular', 'linen', 'pack', 10, null, 580),
  ('New sheets',     'Sheet – new',     'Sábana nueva',   'linen', 'pack', 10, null, 590)
 ) as i(group_name, name, name_es, category, count_mode, pack_size, pieces_per_load, sort_order)
  join public.wash_groups g on g.plant_id = p.id and g.name = i.group_name
 where p.name = 'Miami';

-- ── Washroom machines (owner 2026-11-01): 3 TVs = washers 1–3, washers 4–6, dryers 1–4 ──
-- Model strings are vendor descriptions only; PlantBoard never weighs anything. Dryer models TBD (owner).
-- load_factor (standard loads per load run): Washer 6 = 1.19, the ratio of its rated size to the
-- standard washers', because it is filled to its larger size (owner 2026-11-01). Every other machine 1.00.
insert into public.machines (org_id, plant_id, area_id, name, kind, vendor, model, load_factor)
select a.org_id, a.plant_id, a.id, m.name, m.kind::app.machine_kind, m.vendor, m.model, m.load_factor
  from public.areas a
  join public.plants p on p.id = a.plant_id and p.name = 'Miami'
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
  ('Washer 1', 'washer', 'Milnor', '135 lb hard-mount', 1.00),
  ('Washer 2', 'washer', 'Milnor', '135 lb hard-mount', 1.00),
  ('Washer 3', 'washer', 'Milnor', '135 lb hard-mount', 1.00),
  ('Washer 4', 'washer', 'Milnor', '135 lb hard-mount', 1.00),
  ('Washer 5', 'washer', 'Milnor', '135 lb hard-mount', 1.00),
  ('Washer 6', 'washer', 'Milnor', '160 lb soft-mount', 1.19),
  ('Dryer 1',  'dryer',  null,     null,     1.00),
  ('Dryer 2',  'dryer',  null,     null,     1.00),
  ('Dryer 3',  'dryer',  null,     null,     1.00),
  ('Dryer 4',  'dryer',  null,     null,     1.00)
 ) as m(name, kind, vendor, model, load_factor)
 where a.kind = 'washroom';

-- Plant utilities and finishing machines (owner 2026-11-05; data migration 20261105170550 for the cloud).
-- The utilities serve the whole plant and sit in the washroom area; they can be marked down like washers.
insert into public.machines (org_id, plant_id, area_id, name, kind)
select a.org_id, a.plant_id, a.id, m.name, m.kind::app.machine_kind
  from public.areas a
  join public.plants p on p.id = a.plant_id and p.name = 'Miami'
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
  join (values
   ('Compressor',       'utility', 'washroom'),
   ('Soap machine',     'utility', 'washroom'),
   ('Boiler',           'utility', 'washroom'),
   ('Water pump',       'utility', 'washroom'),
   ('Ironer',           'ironer',  'finishing'),
   ('Folder',           'folder',  'finishing'),
   ('Wrapping machine', 'wrapper', 'finishing')) as m(name, kind, area_kind) on a.kind = m.area_kind::app.area_kind;

-- ── Shifts (A6), per area; days = the day a shift STARTS (0 = Sun … 6 = Sat) ──
-- Thursday variants are separate rows with the same name. No washroom midday shift (owner).
-- Load-out (owner 2026-11-06; data migration 20261106025433_add_load_out for the cloud): soil bags (never
-- washed, packs of 5) and the 4+1 routes with their load times and weekdays (0 = Sun … 6 = Sat).
insert into public.item_types (org_id, plant_id, wash_group_id, name, name_i18n, category, count_mode, pack_size, washed, sort_order)
select p.org_id, p.id, null, 'Soil bags', '{"es":"Bolsas"}'::jsonb, 'other', 'pack', 5, false, 900
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami';
insert into public.routes (org_id, plant_id, name, load_time, days_of_week, sort_order)
select p.org_id, p.id, v.name, v.load_time::time, v.days::smallint[], v.sort_order
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
   ('Route 21', '03:30', '{1,2,4,5}',   10),
   ('Route 11', '04:30', '{1,4}',       20),
   ('Route 5',  '04:30', '{2,5}',       30),
   ('Route 2',  '05:00', '{1,2,3,4,5}', 40),
   ('Route 4',  '05:30', '{1,2,4,5}',   50)) as v(name, load_time, days, sort_order)
 where p.name = 'Miami';

-- Holidays (owner 2026-11-05; data migration 20261106022343_add_plant_holidays for the cloud): closed only on
-- Christmas Day, New Year's Day and Thanksgiving Day (4th Thursday of November). No shift instances then.
insert into public.plant_holidays (org_id, plant_id, name, name_i18n, month, day, weekday, nth)
select p.org_id, p.id, v.name, v.name_i18n, v.month, v.day, v.weekday, v.nth
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
   ('Christmas Day',    '{"es":"Navidad"}'::jsonb,            12::smallint, 25::smallint, null::smallint, null::smallint),
   ('New Year''s Day',  '{"es":"Año Nuevo"}'::jsonb,           1,           1,            null,           null),
   ('Thanksgiving Day', '{"es":"Día de Acción de Gracias"}'::jsonb, 11,     null,         4,              4)) as v(name, name_i18n, month, day, weekday, nth)
 where p.name = 'Miami';

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

-- Outside customers (owner 2026-11-06; data migrations 20261107003619_add_customers and
-- 20261107021214_add_aa_linen_products for the cloud): AA Linen and its own 12 wash groups (owner
-- 2026-11-07), with the owner's Spanish names and formulas (by external_no). Loads per bin are filled in by
-- the owner in the app, except Mats = 4 per bin. Cotton tablecloths use formula 3 (our white tablecloths';
-- flagged to the owner: no cotton tablecloth group of our own).
insert into public.customers (org_id, plant_id, name, name_i18n, sort_order)
select p.org_id, p.id, 'AA Linen', '{}'::jsonb, 10
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami';

insert into public.wash_groups (org_id, plant_id, customer_id, name, name_i18n, color_hex, sort_order,
                                loads_per_bin, allow_bin_estimates, wash_formula_id)
select c.org_id, c.plant_id, c.id, v.name, jsonb_build_object('es', v.es), v.color, v.sort_order,
       v.per_bin, v.per_bin is not null, f.id
  from public.customers c
  join public.plants p on p.id = c.plant_id and p.name = 'Miami'
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
   ('Kitchen towels',            'Toallas de cocina',             '#C2410C', 1000, null::numeric, '5'),
   ('White aprons',              'Delantales blancos',            '#0E7490', 1010, null,          '5'),
   ('Black aprons',              'Delantales negros',             '#4F46E5', 1015, null,          '4'),
   ('Mats',                      'Alfombras',                     '#A16207', 1020, 4,             '1'),
   ('White napkins',             'Servilletas blancas',           '#15803D', 1030, null,          '3'),
   ('Colored napkins',           'Servilletas de color',          '#A21CAF', 1035, null,          '4'),
   ('White tablecloths',         'Manteles blancos',              '#E11D48', 1040, null,          '3'),
   ('Colored tablecloths',       'Manteles de color',             '#BE185D', 1043, null,          '4'),
   ('Cotton tablecloths',        'Manteles de algodón',           '#4D7C0F', 1046, null,          '3'),
   ('Stained white napkins',     'Servilletas blancas manchadas', '#9333EA', 1050, null,          '5'),
   ('Stained white tablecloths', 'Manteles blancos manchados',    '#0284C7', 1060, null,          '5'),
   ('Stained hotel towels',      'Toallas de hotel manchadas',    '#059669', 1070, null,          '5'))
   as v(name, es, color, sort_order, per_bin, formula_no)
  left join public.wash_formulas f on f.plant_id = c.plant_id and f.external_no = v.formula_no
 where c.name = 'AA Linen';

-- Estimate filter chips (owner 2026-11-09; data migration 20261109182651_add_wash_group_category for the
-- cloud): every ADB group, ours and AA Linen's, gets its category. Same mapping as the migration.
with own(name, category) as (values
  ('Black mats', 'mats'), ('Colored mats', 'mats'), ('Charcoal mats', 'mats'), ('Scraper mats', 'mats'),
  ('City & Brito mats', 'mats'), ('Presidente logo mats', 'mats'), ('Logo mats', 'mats'),
  ('Dust & wet mops', 'mops'), ('Microfiber mops', 'mops'),
  ('Kitchen towels', 'towels_aprons'), ('Microfiber towels', 'towels_aprons'), ('Mechanic towels', 'towels_aprons'),
  ('White aprons', 'towels_aprons'), ('Black aprons', 'towels_aprons'), ('Coats (white)', 'towels_aprons'),
  ('White tablecloths', 'tablecloths'), ('Black tablecloths', 'tablecloths'), ('Red & blue tablecloths', 'tablecloths'),
  ('Old sheets', 'sheets'), ('Regular sheets', 'sheets'), ('New sheets', 'sheets')
), aa(name, category) as (values
  ('Kitchen towels', 'towels_aprons'), ('White aprons', 'towels_aprons'), ('Black aprons', 'towels_aprons'),
  ('Stained hotel towels', 'towels_aprons'), ('Mats', 'mats'),
  ('White napkins', 'napkins'), ('Colored napkins', 'napkins'), ('Stained white napkins', 'napkins'),
  ('White tablecloths', 'tablecloths'), ('Colored tablecloths', 'tablecloths'), ('Cotton tablecloths', 'tablecloths'),
  ('Stained white tablecloths', 'tablecloths')
), target as (
  select g.id, coalesce(own.category, 'napkins') as category
    from public.wash_groups g
    join public.plants p on p.id = g.plant_id and p.name = 'Miami'
    join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
    left join own on own.name = g.name
   where g.customer_id is null and (own.name is not null or g.name like 'Napkins – %')
  union all
  select g.id, aa.category
    from public.wash_groups g
    join public.customers c on c.id = g.customer_id and c.plant_id = g.plant_id and c.name = 'AA Linen'
    join public.plants p on p.id = g.plant_id and p.name = 'Miami'
    join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
    join aa on aa.name = g.name
)
update public.wash_groups g
   set category = t.category
  from target t
 where g.id = t.id;

-- Mats by basket (owner 2026-11-09, final; data migration 20261109184351_regroup_mats_by_basket for the
-- cloud). The groups and items above are the catalog as it was; the SAME function the migration runs turns
-- it into the 4 basket groups, so a fresh database ends exactly like the cloud (audit rows included):
-- Black mats (+ Black City mats, Scraper mat 3×5), Colored mats (+ Presidente and other logo mats),
-- Charcoal mats, Brito mats (was "City & Brito mats"; red Brito only). Scraper mats, Presidente logo mats and
-- Logo mats are left inactive, with no items.
select app.apply_mat_basket_groups(p.id)
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami';

-- Mats are "Alfombras" in Spanish (owner 2026-11-09, ours and AA Linen's; data migration
-- 20261109212849_rename_mats_alfombras for the cloud). The "Tapete…" es names above are the catalog as it was;
-- the SAME function the migration runs turns every mat group/item es name that still starts with "Tapete" into
-- "Alfombra…" ("Tapetes negros" → "Alfombras negras", "Tapete negro 3×5" → "Alfombra negra 3×5").
select app.apply_mat_spanish_names(p.id)
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami';

-- Spanish machine names (owner 2026-11-09; data migration 20261109215633_add_machine_spanish_names for the
-- cloud): the SAME function sets name_i18n.es on every machine without one (Ironer → Planchadora, Folder →
-- Dobladora, Boiler → Caldera, Compressor → Compresor, Water pump → Bomba de agua, Soap machine → Máquina de
-- jabón, Wrapping machine → Empacadora, Washer N → Lavadora N, Dryer N → Secadora N).
select app.apply_machine_spanish_names(p.id)
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami';
