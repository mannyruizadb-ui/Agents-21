-- DATA migration (owner 2026-11-04): container factors and preset chip colors for the ADB wash groups
-- (org 'americas-dust-busters', plant 'Miami'). The cloud already has the seed, so seed.sql alone would
-- not reach it; supabase/seed.sql carries the same values for fresh databases (where this migration
-- runs before the seed and changes nothing).
--
-- Never overwrites an edit: a factor is set only where it is still null (and the matching allow_*
-- flag is turned on only together with that new factor); a color only where it is still the column
-- default '#64748B'. Re-running it changes nothing.
--
-- Loads per FULL container (owner round 3; estimates, not rules → approximate):
--   every mat group 3.5 per basket · Kitchen towels 2 per basket, 2.5 per bin · the three sheet groups,
--   all 14 napkin groups and the three tablecloth groups 2 per bin. Every other factor stays null.
--
-- Colors follow the goods' color in the name (black, white, navy, pink, red & blue, bone, …); groups
-- whose name has no color (Scraper, City & Brito, logo mats, mops, towels) get distinct mid-tone hues.
-- Mid-tones are ≥ 3:1 against both a white card (#FFFFFF) and the TV's dark card (#0B0F14). Black
-- goods are ≥ 3:1 on white only and white goods on dark only: the chip keeps the goods' real color,
-- the UI draws a 2px currentColor border around every chip, and the group NAME is always shown, so the
-- color is never the only cue. Same-color goods (e.g. the black or white groups) are deliberately
-- close: the chip says "black goods", the name says which.
with v(name, color_hex, loads_per_basket, loads_per_bin) as (values
  ('Black mats',                          '#1F1F1F', 3.5::numeric, null::numeric),
  ('Colored mats',                        '#B45309', 3.5, null),
  ('Charcoal mats',                       '#52525B', 3.5, null),
  ('Scraper mats',                        '#7C5A3C', 3.5, null),
  ('City & Brito mats',                   '#0F766E', 3.5, null),
  ('Presidente logo mats',                '#7C3AED', 3.5, null),
  ('Logo mats',                           '#C026D3', 3.5, null),
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
