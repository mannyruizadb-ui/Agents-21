-- Mats by basket (owner 2026-11-09, final): mats are estimated, queued AND tapped at the BASKET level,
-- exactly as the drivers offload them. The washmen split a basket into separate loads, but every load is
-- recorded against its basket (= its wash group); there are no size taps (sizes are counted at finishing).
-- Our own mat wash groups become the 4 baskets:
--   * Black mats    – blacks, Black City mats, black logos (e.g. Barry University), scraper mats;
--   * Colored mats  – red, green, brown…, Presidente logos, colored logos;
--   * Charcoal mats – its own basket (unchanged);
--   * Brito mats    – red Brito, its own basket, washed separately (was "City & Brito mats").
--
-- DATA, ADB plant only, through app.apply_mat_basket_groups(plant) (seed.sql calls the same function, so a
-- fresh database and the cloud end in the same state by the same code):
--   1. Rename "City & Brito mats" → "Brito mats" (es "Tapetes Brito").
--   2. Items move (item_types.wash_group_id): "Black City mat *" (from Brito) and "Scraper mat 3×5" (from
--      Scraper mats) → Black mats; "Presidente logo mat 5×7" and "Logo mat 3×5/4×6/5×7" (from Presidente
--      logo mats / Logo mats) → Colored mats. "Red Brito mat *" stay in Brito mats.
--      RECONCILIATION CAVEAT: black-based logo mats physically go in the BLACK basket, but finishing counts
--      them as logo mats, which now belong to Colored mats. Per group, reconciliation will show black logos
--      as finished Colored mats that were washed as Black mats (the plant total is unaffected).
--   3. "Scraper mats", "Presidente logo mats" and "Logo mats" are DEACTIVATED (active = false, never
--      deleted): their history (washer cycles, estimates, queue items, finished goods snapshots) stays as
--      recorded. The write RPCs already refuse inactive groups.
--   4. The 4 basket groups: formula external_no 1, category 'mats', active, basket + bin estimates allowed
--      with the existing factors (null filled with 3.5 per basket / 4 per bin, never overwritten), the
--      default estimate unit 'basket' (only when still 'load'; a 'bin' default is kept), and a
--      distinct colour preset: Brito moves from teal #0F766E to red #EF4444 (red Brito), only if still at
--      the old preset. Black #1F1F1F, Colored #B45309 and Charcoal #52525B are unchanged.
--   Open queue items or estimates in the deactivated groups, open queue items of a moved item, items still
--   left in a deactivated group and formulas pointing at one are LEFT AS THEY ARE and reported (NOTICE +
--   the returned jsonb). Formula 6 ("Logo mats") is no longer used by an active group of ours; it is kept.
--
-- Idempotent: every step matches the old state only (by name and current group), and each UPDATE skips rows
-- already in the target state, so a re-run changes nothing and writes no audit rows. Runs as postgres, so
-- the app.audit trigger records each change with a null actor; the setup guards return early (no auth.uid()).
-- Not callable through the API (revoked from public, anon, authenticated).

create function app.apply_mat_basket_groups(p_plant_id uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_black      uuid;
  v_colored    uuid;
  v_charcoal   uuid;
  v_brito      uuid;
  v_scraper    uuid;
  v_presidente uuid;
  v_logo       uuid;
  v_f1         uuid;
  v_dead       uuid[];
  v_renamed    int := 0;
  v_moved      int := 0;
  v_n          int;
  v_deact      int := 0;
  v_updated    int := 0;
  v_result     jsonb;
begin
  if p_plant_id is null or not exists (select 1 from public.plants p where p.id = p_plant_id) then
    raise exception 'VALIDATION_FAILED' using detail = 'apply_mat_basket_groups: unknown plant';
  end if;

  -- 1. Rename (skipped once a "Brito mats" group exists).
  update public.wash_groups g
     set name = 'Brito mats',
         name_i18n = g.name_i18n || '{"es":"Tapetes Brito"}'::jsonb
   where g.plant_id = p_plant_id and g.customer_id is null and g.name = 'City & Brito mats'
     and not exists (select 1 from public.wash_groups x
                      where x.plant_id = p_plant_id and x.customer_id is null and x.name = 'Brito mats');
  get diagnostics v_renamed = row_count;

  select g.id into v_black    from public.wash_groups g where g.plant_id = p_plant_id and g.customer_id is null and g.name = 'Black mats';
  select g.id into v_colored  from public.wash_groups g where g.plant_id = p_plant_id and g.customer_id is null and g.name = 'Colored mats';
  select g.id into v_charcoal from public.wash_groups g where g.plant_id = p_plant_id and g.customer_id is null and g.name = 'Charcoal mats';
  select g.id into v_brito    from public.wash_groups g where g.plant_id = p_plant_id and g.customer_id is null and g.name = 'Brito mats';
  select g.id into v_scraper    from public.wash_groups g where g.plant_id = p_plant_id and g.customer_id is null and g.name = 'Scraper mats';
  select g.id into v_presidente from public.wash_groups g where g.plant_id = p_plant_id and g.customer_id is null and g.name = 'Presidente logo mats';
  select g.id into v_logo       from public.wash_groups g where g.plant_id = p_plant_id and g.customer_id is null and g.name = 'Logo mats';
  select f.id into v_f1 from public.wash_formulas f where f.plant_id = p_plant_id and f.external_no = '1';

  -- A missing basket group or formula 1 means the catalog was changed by hand: stop rather than half-apply.
  if v_black is null or v_colored is null or v_charcoal is null or v_brito is null or v_f1 is null then
    raise exception 'VALIDATION_FAILED' using detail = format(
      'apply_mat_basket_groups: missing %s', concat_ws(', ',
        case when v_black    is null then 'Black mats' end,
        case when v_colored  is null then 'Colored mats' end,
        case when v_charcoal is null then 'Charcoal mats' end,
        case when v_brito    is null then 'Brito mats' end,
        case when v_f1       is null then 'formula 1' end));
  end if;
  v_dead := array_remove(array[v_scraper, v_presidente, v_logo], null);

  -- 2. Items move, only from the group the owner named (a later move in the app is never undone).
  update public.item_types i set wash_group_id = v_black
   where i.plant_id = p_plant_id and i.wash_group_id = v_brito and i.name like 'Black City mat %';
  get diagnostics v_n = row_count;  v_moved := v_moved + v_n;
  update public.item_types i set wash_group_id = v_black
   where i.plant_id = p_plant_id and i.wash_group_id = v_scraper and i.name = 'Scraper mat 3×5';
  get diagnostics v_n = row_count;  v_moved := v_moved + v_n;
  update public.item_types i set wash_group_id = v_colored
   where i.plant_id = p_plant_id
     and ((i.wash_group_id = v_presidente and i.name = 'Presidente logo mat 5×7')
          or (i.wash_group_id = v_logo and i.name in ('Logo mat 3×5', 'Logo mat 4×6', 'Logo mat 5×7')));
  get diagnostics v_n = row_count;  v_moved := v_moved + v_n;

  -- 3. Deactivate (never delete).
  update public.wash_groups g set active = false
   where g.plant_id = p_plant_id and g.id = any (v_dead) and g.active;
  get diagnostics v_deact = row_count;

  -- 4. The 4 basket groups.
  update public.wash_groups g
     set wash_formula_id        = v_f1,
         category               = 'mats',
         active                 = true,
         loads_per_basket       = coalesce(g.loads_per_basket, 3.5),
         loads_per_bin          = coalesce(g.loads_per_bin, 4),
         allow_basket_estimates = true,
         allow_bin_estimates    = true,
         default_estimate_unit  = case when g.default_estimate_unit = 'load' then 'basket'::app.qty_unit else g.default_estimate_unit end,
         color_hex              = case when g.id = v_brito and g.color_hex = '#0F766E' then '#EF4444' else g.color_hex end
   where g.plant_id = p_plant_id and g.id in (v_black, v_colored, v_charcoal, v_brito)
     and (g.wash_formula_id is distinct from v_f1 or g.category <> 'mats' or not g.active
          or g.loads_per_basket is null or g.loads_per_bin is null
          or not g.allow_basket_estimates or not g.allow_bin_estimates
          or g.default_estimate_unit = 'load'
          or (g.id = v_brito and g.color_hex = '#0F766E'));
  get diagnostics v_updated = row_count;

  -- Report what is left as it is.
  v_result := jsonb_build_object(
    'renamed',            v_renamed,
    'items_moved',        v_moved,
    'groups_deactivated', v_deact,
    'groups_updated',     v_updated,
    'items_left_in_inactive_groups', (
      select coalesce(jsonb_agg(i.name order by i.name), '[]'::jsonb) from public.item_types i
       where i.plant_id = p_plant_id and i.wash_group_id = any (v_dead)),
    'open_queue_items_in_inactive_groups', (
      select count(*) from public.queue_items q
       where q.plant_id = p_plant_id and q.wash_group_id = any (v_dead) and q.status in ('queued', 'in_progress')),
    'open_queue_items_of_moved_items', (
      select count(*) from public.queue_items q join public.item_types i on i.id = q.item_type_id and i.plant_id = q.plant_id
       where q.plant_id = p_plant_id and q.status in ('queued', 'in_progress') and q.wash_group_id <> i.wash_group_id),
    'latest_estimates_in_inactive_groups', (
      select count(*) from (select distinct on (e.wash_group_id) e.qty from public.soil_estimates e
                             where e.plant_id = p_plant_id and e.wash_group_id = any (v_dead)
                             order by e.wash_group_id, e.entered_at desc, e.id desc) x
       where x.qty > 0),
    'formulas_pointing_at_inactive_groups', (
      select count(*) from public.wash_formulas f where f.plant_id = p_plant_id and f.wash_group_id = any (v_dead)));
  raise notice 'apply_mat_basket_groups(%): %', p_plant_id, v_result;
  return v_result;
end;
$$;
comment on function app.apply_mat_basket_groups(uuid) is
  'Owner 2026-11-09 (mats by basket), one-shot data change for one plant''s catalog, shared by the data migration 20261109184351 (cloud, ADB plant) and seed.sql: renames City & Brito mats → Brito mats (es Tapetes Brito); moves Black City mat * and Scraper mat 3×5 → Black mats, Presidente logo mat 5×7 and Logo mat 3×5/4×6/5×7 → Colored mats; deactivates Scraper mats, Presidente logo mats and Logo mats; sets the 4 basket groups (Black, Colored, Charcoal, Brito mats) to formula 1, category mats, active, basket/bin estimates with factors kept (null → 3.5 / 4), default_estimate_unit basket (only when still load), Brito red #EF4444 if still teal #0F766E. Idempotent (old state matched by name and current group; target-state rows skipped). Leaves open queue items, estimates and other rows of the deactivated groups as they are and returns/NOTICEs their counts. VALIDATION_FAILED if a basket group or formula 1 is missing. Postgres only.';
revoke all on function app.apply_mat_basket_groups(uuid) from public, anon, authenticated;

-- ── DATA: the ADB plant (no row on a fresh database: seed.sql calls the function itself) ──
select app.apply_mat_basket_groups(p.id)
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami';
