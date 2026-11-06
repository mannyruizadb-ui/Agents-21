-- Soil bags in Spanish: "Bolsas" (owner 2026-11-06, E). Data migration for the cloud (seed.sql carries
-- the same value for local resets). Only the ADB plant's seeded "Soil bags" item; other languages and
-- every other key of name_i18n are kept.
update public.item_types i
   set name_i18n = i.name_i18n || '{"es":"Bolsas"}'::jsonb
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where i.plant_id = p.id and p.name = 'Miami' and i.name = 'Soil bags'
   and i.name_i18n ->> 'es' is distinct from 'Bolsas';
