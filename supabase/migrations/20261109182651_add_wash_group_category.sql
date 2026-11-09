-- Wash group category (owner 2026-11-09): the estimates screen gets filter chips (Napkins, Tablecloths,
-- Sheets, Mats, Towels & aprons, Mops). The chip a group falls under is DATA on the group, not a name
-- pattern in the client, so a group the owner adds or renames in Setup keeps (or gets) its chip.
--
-- 1. wash_groups.category: text, not null, default 'other', CHECK on the 7 values below. Labels are
--    translated in the client (src/locales), so the stored value is a stable key, never shown as is.
-- 2. Write path unchanged: the same RLS policies (owner/manager on our own groups; customer groups
--    owner-only through app.guard_wash_group_customer) plus a column UPDATE grant like the other setup
--    columns (20261103212053). INSERT and SELECT are table-level grants, so the new column is readable by
--    everyone who reads wash_groups (owner, manager, lead, viewer, the plant's display) and insertable on
--    the same terms as the rest of the row. anon has no table privileges (20261107010437).
-- 3. Data for the ADB plant (Miami): our 33 groups and AA Linen's 12. Idempotent: only rows still at the
--    default 'other' are set, so a re-run, or a category the owner already changed in the app, is left
--    alone. Runs as postgres, so the app.audit trigger records each change with a null actor. Groups not
--    matched by name (renamed in the cloud, or added in the app) stay 'other' and are listed in a NOTICE.

-- ── 1. Column ─────────────────────────────────────────────────────────────
alter table public.wash_groups
  add column category text not null default 'other'
    constraint wash_groups_category_check
    check (category in ('napkins', 'tablecloths', 'sheets', 'mats', 'towels_aprons', 'mops', 'other'));

comment on column public.wash_groups.category is
  'Estimate filter chip (owner 2026-11-09): napkins, tablecloths, sheets, mats, towels_aprons, mops or other (default). A stable key; the client translates the label. Edited by whoever may edit the group (owner/manager; customer groups owner-only).';

-- ── 2. Column UPDATE grant (same path as name, color_hex, sort_order, ...) ──
grant update (category) on public.wash_groups to authenticated;

-- ── 3. ADB data: our own groups and AA Linen's ────────────────────────────
with adb as (
  select p.id as plant_id
    from public.plants p
    join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
   where p.name = 'Miami'
),
own(name, category) as (values
  ('Black mats',             'mats'),
  ('Colored mats',           'mats'),
  ('Charcoal mats',          'mats'),
  ('Scraper mats',           'mats'),
  ('City & Brito mats',      'mats'),
  ('Presidente logo mats',   'mats'),
  ('Logo mats',              'mats'),
  ('Dust & wet mops',        'mops'),
  ('Microfiber mops',        'mops'),
  ('Kitchen towels',         'towels_aprons'),
  ('Microfiber towels',      'towels_aprons'),
  ('Mechanic towels',        'towels_aprons'),
  ('White aprons',           'towels_aprons'),
  ('Black aprons',           'towels_aprons'),
  ('Coats (white)',          'towels_aprons'),
  ('White tablecloths',      'tablecloths'),
  ('Black tablecloths',      'tablecloths'),
  ('Red & blue tablecloths', 'tablecloths'),
  ('Old sheets',             'sheets'),
  ('Regular sheets',         'sheets'),
  ('New sheets',             'sheets')
),
aa(name, category) as (values
  ('Kitchen towels',            'towels_aprons'),
  ('White aprons',              'towels_aprons'),
  ('Black aprons',              'towels_aprons'),
  ('Stained hotel towels',      'towels_aprons'),
  ('Mats',                      'mats'),
  ('White napkins',             'napkins'),
  ('Colored napkins',           'napkins'),
  ('Stained white napkins',     'napkins'),
  ('White tablecloths',         'tablecloths'),
  ('Colored tablecloths',       'tablecloths'),
  ('Cotton tablecloths',        'tablecloths'),
  ('Stained white tablecloths', 'tablecloths')
),
target as (
  -- Our own goods: the named groups, plus every "Napkins – <color>" group.
  select g.id, coalesce(own.category, 'napkins') as category
    from public.wash_groups g
    join adb on adb.plant_id = g.plant_id
    left join own on own.name = g.name
   where g.customer_id is null
     and (own.name is not null or g.name like 'Napkins – %')
  union all
  -- AA Linen's groups.
  select g.id, aa.category
    from public.wash_groups g
    join adb on adb.plant_id = g.plant_id
    join public.customers c on c.id = g.customer_id and c.plant_id = g.plant_id and c.name = 'AA Linen'
    join aa on aa.name = g.name
)
update public.wash_groups g
   set category = t.category
  from target t
 where g.id = t.id
   and g.category = 'other';

do $$
declare
  v_left text;
begin
  select string_agg(g.name || coalesce(' (' || c.name || ')', ''), ', ' order by g.sort_order)
    into v_left
    from public.wash_groups g
    join public.plants p on p.id = g.plant_id and p.name = 'Miami'
    join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
    left join public.customers c on c.id = g.customer_id
   where g.active and g.category = 'other';
  if v_left is not null then
    raise notice 'wash_groups.category: active ADB groups left at ''other'' (set them in Setup): %', v_left;
  end if;
end;
$$;
