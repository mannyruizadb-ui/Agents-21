-- Mats are "Alfombras" in Spanish (owner decision, repeated 2026-11-09): for our mats and AA Linen's alike.
-- DATA only (no schema change), ADB plant, through app.apply_mat_spanish_names(plant); seed.sql calls the same
-- function after app.apply_mat_basket_groups, so a fresh database and the cloud end in the same state by the
-- same code (audit rows included).
--
-- Only name_i18n.es changes, and only on rows whose es value still STARTS WITH "Tapete" (an owner edit made in
-- the app is never overwritten; AA Linen's "Alfombras" is left alone):
--   * mat wash groups (category 'mats', active or not), e.g. "Tapetes negros" → "Alfombras negras",
--     "Tapetes de color" → "Alfombras de color", "Tapetes carbón" → "Alfombras carbón",
--     "Tapetes Brito" → "Alfombras Brito", "Tapetes raspadores" → "Alfombras raspadoras",
--     "Tapetes con logo Presidente" → "Alfombras con logo Presidente", "Tapetes con logo" → "Alfombras con logo";
--   * mat items (category 'mat'), e.g. "Tapete negro 3×5" → "Alfombra negra 3×5",
--     "Tapete City negro 3×10" → "Alfombra City negra 3×10", "Tapete Brito rojo 4×6" → "Alfombra Brito roja 4×6",
--     "Tapete raspador 3×5" → "Alfombra raspadora 3×5". Sizes and every other word are kept.
-- The noun is feminine, so the masculine colour/kind adjectives that follow it agree (app.es_mat_alfombra).
-- Other name_i18n keys (en, ht, …) are kept. Each change is audited by the app.audit trigger (postgres: no
-- actor). Idempotent: a re-run matches nothing and writes no audit row. Not callable through the API.

create function app.es_mat_alfombra(p_es text)
returns text language plpgsql immutable set search_path = '' as $$
declare
  v   text := p_es;
  adj text[];
begin
  if v is null or v !~ '^Tapetes?\M' then
    return v;
  end if;
  v := regexp_replace(v, '^Tapetes\M', 'Alfombras');
  v := regexp_replace(v, '^Tapete\M', 'Alfombra');
  -- Masculine → feminine (plural first; \m…\M are whole-word bounds, so "rojo" never touches "rojos").
  foreach adj slice 1 in array array[
    ['negros', 'negras'], ['negro', 'negra'], ['rojos', 'rojas'], ['rojo', 'roja'],
    ['raspadores', 'raspadoras'], ['raspador', 'raspadora'], ['blancos', 'blancas'], ['blanco', 'blanca'],
    ['amarillos', 'amarillas'], ['amarillo', 'amarilla'], ['morados', 'moradas'], ['morado', 'morada'],
    ['rosados', 'rosadas'], ['rosado', 'rosada'], ['oscuros', 'oscuras'], ['oscuro', 'oscura'],
    ['claros', 'claras'], ['claro', 'clara'], ['nuevos', 'nuevas'], ['nuevo', 'nueva'],
    ['viejos', 'viejas'], ['viejo', 'vieja'], ['pequeños', 'pequeñas'], ['pequeño', 'pequeña']]
  loop
    v := regexp_replace(v, '\m' || adj[1] || '\M', adj[2], 'g');
  end loop;
  return v;
end;
$$;
comment on function app.es_mat_alfombra(text) is
  'Owner 2026-11-09 (mats are "Alfombras" in Spanish): turns a Spanish mat name that starts with "Tapete"/"Tapetes" into "Alfombra"/"Alfombras", making the masculine adjectives that follow feminine (negro → negra, rojo → roja, raspador → raspadora, …); sizes and other words kept. Any other text is returned unchanged. Used by app.apply_mat_spanish_names. Postgres only.';
revoke all on function app.es_mat_alfombra(text) from public, anon, authenticated;

create function app.apply_mat_spanish_names(p_plant_id uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_groups int := 0;
  v_items  int := 0;
  v_result jsonb;
begin
  if p_plant_id is null or not exists (select 1 from public.plants p where p.id = p_plant_id) then
    raise exception 'VALIDATION_FAILED' using detail = 'apply_mat_spanish_names: unknown plant';
  end if;

  update public.wash_groups g
     set name_i18n = g.name_i18n || jsonb_build_object('es', app.es_mat_alfombra(g.name_i18n ->> 'es'))
   where g.plant_id = p_plant_id and g.category = 'mats'
     and g.name_i18n ->> 'es' ~ '^Tapetes?\M';
  get diagnostics v_groups = row_count;

  update public.item_types i
     set name_i18n = i.name_i18n || jsonb_build_object('es', app.es_mat_alfombra(i.name_i18n ->> 'es'))
   where i.plant_id = p_plant_id and i.category = 'mat'
     and i.name_i18n ->> 'es' ~ '^Tapetes?\M';
  get diagnostics v_items = row_count;

  v_result := jsonb_build_object(
    'groups_renamed', v_groups,
    'items_renamed',  v_items,
    -- Anything still saying "Tapete" anywhere in its es name (an owner edit, or a mat row in another category).
    'tapete_left', (
      select coalesce(jsonb_agg(x.es order by x.es), '[]'::jsonb) from (
        select g.name_i18n ->> 'es' as es from public.wash_groups g
         where g.plant_id = p_plant_id and g.name_i18n ->> 'es' ilike '%tapete%'
        union all
        select i.name_i18n ->> 'es' from public.item_types i
         where i.plant_id = p_plant_id and i.name_i18n ->> 'es' ilike '%tapete%') x));
  raise notice 'apply_mat_spanish_names(%): %', p_plant_id, v_result;
  return v_result;
end;
$$;
comment on function app.apply_mat_spanish_names(uuid) is
  'Owner 2026-11-09 (mats are "Alfombras" in Spanish, ours and AA Linen''s), one-shot data change for one plant, shared by the data migration 20261109212849 (cloud, ADB plant) and seed.sql: sets name_i18n.es of every mat wash group (category mats, active or not) and mat item (category mat) whose es value still starts with "Tapete" to app.es_mat_alfombra(es) ("Tapetes negros" → "Alfombras negras", "Tapete negro 3×5" → "Alfombra negra 3×5"). Other keys and owner-edited names are kept. Idempotent. Returns/NOTICEs the counts and any es name still containing "Tapete". VALIDATION_FAILED on an unknown plant. Postgres only.';
revoke all on function app.apply_mat_spanish_names(uuid) from public, anon, authenticated;

-- ── DATA: the ADB plant (no row on a fresh database: seed.sql calls the function itself) ──
select app.apply_mat_spanish_names(p.id)
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami';
