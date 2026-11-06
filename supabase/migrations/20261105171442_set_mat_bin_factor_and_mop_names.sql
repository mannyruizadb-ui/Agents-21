-- DATA (owner 2026-11-05) for the ADB plant; seed.sql carries the same values for fresh databases.
-- * Mats: 4 loads per full bin (AA Linen mats arrive in bins), bins allowed, for all 7 mat groups.
--   Set only where loads_per_bin is still null, so an edit made in the app is never overwritten.
-- * Spanish names: mops are "Mapos" (owner's wording). Changed only where the name is still the
--   original seed text.
-- (Tablecloths at 2 loads per bin: confirmed by the owner; already set.)

update public.wash_groups g
   set loads_per_bin = 4, allow_bin_estimates = true
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where g.plant_id = p.id and p.name = 'Miami'
   and g.name in ('Black mats', 'Colored mats', 'Charcoal mats', 'Scraper mats', 'City & Brito mats',
                  'Presidente logo mats', 'Logo mats')
   and g.loads_per_bin is null;

update public.wash_groups g
   set name_i18n = g.name_i18n || pg_catalog.jsonb_build_object('es', v.es_new)
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
   ('Dust & wet mops', 'Mopas de polvo y trapeadores', 'Mapos de polvo y trapeadores'),
   ('Microfiber mops', 'Mopas de microfibra',          'Mapos de microfibra')) as v(name, es_old, es_new)
 where g.plant_id = p.id and p.name = 'Miami' and g.name = v.name
   and g.name_i18n ->> 'es' = v.es_old;
