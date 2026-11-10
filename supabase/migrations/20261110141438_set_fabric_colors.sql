-- Fabric colours (owner 2026-11-10): the finishing entry screen and the boards colour each napkin,
-- tablecloth and sheet chip by its real fabric colour, and the white / black wash groups by theirs.
-- DATA only (no schema change), through app.apply_fabric_colors(plant); seed.sql calls the same function, so
-- a fresh database and the cloud end in the same state by the same code. Matching is by NAME within the plant
-- (case and extra spaces ignored, – or - accepted), so it also covers owner-added items that follow the names.
--
-- Items (item_types, category 'linen' only; towels, aprons, mops and mats keep their colour):
--   * names starting "Sheet"                          → #FFFFFF
--   * names starting "Napkin" or "Tablecloth", by the colour the name ENDS with (longest match first):
--     dark navy blue w/ stripe #172554 · navy blue w/ stripe #1E3A8A · black w/ stripe #000000 ·
--     navy blue #1E3A8A · …white (regular / new / cotton / round white) #FFFFFF · …black (cotton / round
--     black) #000000 · bone #E7DCC4 · chambray #8FA9C8 · green #15803D · red #DC2626 · pink #EC4899 ·
--     blue (tablecloths only) #1D4ED8. Any other ending: unchanged.
-- Wash groups (ours AND customer / AA Linen groups, active or not), app.fabric_group_color(name):
--   * "Colored mats" exactly                         → #DC2626 (owner: red, not orange #B45309)
--   * a name with the word "white" or "sheet(s)"     → #FFFFFF (White tablecloths, White aprons, Coats (white),
--     Napkins – Regular / New / Cotton White, Stained white napkins / tablecloths, AA White napkins, New /
--     Regular / Old sheets …)
--   * a name with the word "black"                   → #000000 (Black mats was #1F1F1F, Black aprons, Black
--     tablecloths, Napkins – Black / Black w/ Stripe / Cotton Black …)
--   * both white and black in one name, or neither   → unchanged and listed in the result (Brito #EF4444 and
--     Charcoal #52525B stay; mixed or unsure groups such as Colored napkins / tablecloths, Green & Red,
--     Red & blue, towels, mops are left for the owner).
-- The CHECK on color_hex is ^#[0-9A-Fa-f]{6}$, so #FFFFFF and #000000 are valid.
--
-- Idempotent: each UPDATE skips rows already at the target colour (case-insensitive), so a re-run changes
-- nothing and writes no audit rows. Runs as postgres: app.audit records each change with a null actor; the
-- setup guards return early (no auth.uid()). Not callable through the API (revoked from public, anon,
-- authenticated).

create function app.fabric_item_color(p_name text)
returns text language sql immutable set search_path = '' as $$
  select case
    when v.n ~ '^sheets?\M' then '#FFFFFF'
    when v.n ~ '^(napkin|tablecloth)' then
      case
        when v.n ~ '\mdark navy blue w/ ?stripe$' then '#172554'
        when v.n ~ '\mnavy blue w/ ?stripe$'      then '#1E3A8A'
        when v.n ~ '\mblack w/ ?stripe$'          then '#000000'
        when v.n ~ '\mnavy blue$'                 then '#1E3A8A'
        when v.n ~ '\mwhite$'                     then '#FFFFFF'
        when v.n ~ '\mblack$'                     then '#000000'
        when v.n ~ '\mbone$'                      then '#E7DCC4'
        when v.n ~ '\mchambray$'                  then '#8FA9C8'
        when v.n ~ '\mgreen$'                     then '#15803D'
        when v.n ~ '\mred$'                       then '#DC2626'
        when v.n ~ '\mpink$'                      then '#EC4899'
        when v.n ~ '^tablecloth' and v.n ~ '\mblue$' then '#1D4ED8'
      end
  end
  from (select lower(regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g')) as n) v;
$$;
comment on function app.fabric_item_color(text) is
  'Owner 2026-11-10: fabric colour preset for a napkin / tablecloth / sheet item name (sheets #FFFFFF; napkins and tablecloths by the colour the name ends with, longest match first: dark navy blue w/ stripe, navy blue w/ stripe, black w/ stripe, navy blue, white, black, bone, chambray, green, red, pink, blue (tablecloths only)). Null for any other name. Used by app.apply_fabric_colors. Postgres only.';
revoke all on function app.fabric_item_color(text) from public, anon, authenticated;

create function app.fabric_group_color(p_name text)
returns text language sql immutable set search_path = '' as $$
  select case
    when v.n = 'colored mats' then '#DC2626'
    when (v.n ~ '\mwhite\M' or v.n ~ '\msheets?\M') and v.n !~ '\mblack\M' then '#FFFFFF'
    when v.n ~ '\mblack\M' and not (v.n ~ '\mwhite\M' or v.n ~ '\msheets?\M') then '#000000'
  end
  from (select lower(regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g')) as n) v;
$$;
comment on function app.fabric_group_color(text) is
  'Owner 2026-11-10: colour preset for a wash group name: "Colored mats" #DC2626; the word white or sheet(s) #FFFFFF; the word black #000000; both or neither → null (left unchanged). Used by app.apply_fabric_colors. Postgres only.';
revoke all on function app.fabric_group_color(text) from public, anon, authenticated;

create function app.apply_fabric_colors(p_plant_id uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_items  int := 0;
  v_groups int := 0;
  v_result jsonb;
begin
  if p_plant_id is null or not exists (select 1 from public.plants p where p.id = p_plant_id) then
    raise exception 'VALIDATION_FAILED' using detail = 'apply_fabric_colors: unknown plant';
  end if;

  update public.item_types i
     set color_hex = app.fabric_item_color(i.name)
   where i.plant_id = p_plant_id
     and i.category = 'linen'
     and app.fabric_item_color(i.name) is not null
     and upper(i.color_hex) <> app.fabric_item_color(i.name);
  get diagnostics v_items = row_count;

  update public.wash_groups g
     set color_hex = app.fabric_group_color(g.name)
   where g.plant_id = p_plant_id
     and app.fabric_group_color(g.name) is not null
     and upper(g.color_hex) <> app.fabric_group_color(g.name);
  get diagnostics v_groups = row_count;

  v_result := jsonb_build_object(
    'items', v_items,
    'groups', v_groups,
    -- Groups the rules leave alone (for the owner): name, customer name or null, colour, active.
    'groups_unchanged', (select coalesce(jsonb_agg(jsonb_build_object('name', g.name, 'customer', c.name,
                                                                      'color_hex', g.color_hex, 'active', g.active)
                                                   order by g.customer_id nulls first, g.sort_order, g.name), '[]'::jsonb)
                           from public.wash_groups g
                           left join public.customers c on c.id = g.customer_id
                          where g.plant_id = p_plant_id and app.fabric_group_color(g.name) is null),
    -- Linen items with no fabric-colour rule.
    'linen_items_unchanged', (select coalesce(jsonb_agg(i.name order by i.sort_order, i.name), '[]'::jsonb)
                                from public.item_types i
                               where i.plant_id = p_plant_id and i.category = 'linen' and app.fabric_item_color(i.name) is null));
  -- Counts only in the NOTICE (it lands in the deploy log; never names or customers there).
  raise notice 'apply_fabric_colors: % items, % groups recoloured; % groups and % linen items left unchanged',
    v_items, v_groups, jsonb_array_length(v_result -> 'groups_unchanged'),
    jsonb_array_length(v_result -> 'linen_items_unchanged');
  return v_result;
end;
$$;
comment on function app.apply_fabric_colors(uuid) is
  'Owner 2026-11-10 (fabric colours), one-shot data change for one plant, shared by migration 20261110141438 (cloud, ADB plant) and seed.sql: item_types (category linen) color_hex = app.fabric_item_color(name) and wash_groups (ours and customers'', active or not) color_hex = app.fabric_group_color(name) where a rule matches and the colour differs. Idempotent. Returns the counts, the groups left unchanged and the linen items with no rule; the NOTICE carries counts only (it lands in the deploy log). VALIDATION_FAILED on an unknown plant. Postgres only.';
revoke all on function app.apply_fabric_colors(uuid) from public, anon, authenticated;

-- The ADB plant (no row on a fresh database: seed.sql calls the function itself).
select app.apply_fabric_colors(p.id)
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami';
