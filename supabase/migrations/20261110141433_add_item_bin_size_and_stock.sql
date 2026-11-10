-- Finished-goods entry screen (owner 2026-11-10): two owner-editable numbers per item.
--
-- 1. item_types.bin_size (integer, null = no bin quick-add): pieces in one full bin, for the "+1 bin" quick-add
--    on the entry screen. Sheets come in bins of 500 (old sheets ~600+ and variable, so left null). 1–5,000.
-- 2. item_types.stock_qty (integer, null = unknown): pieces of this item the plant owns, for the "more than
--    we own" warning on the entry screen. 0–10,000,000.
--    Both are plain counts of pieces (integers, no weights). Neither changes a past entry: an entry stores
--    pack_size_used and pieces (generated) itself; bin quick-add is client arithmetic into loose_pieces.
-- 3. Who edits them: OWNER only (owner 2026-11-10: "edit all such numbers in the app"). Column grants for
--    INSERT/UPDATE go to authenticated; app.guard_item_owner_fields (BEFORE INSERT / UPDATE OF bin_size,
--    stock_qty) raises NOT_AUTHORIZED when a non-owner sets or changes either. The item_types RLS policies are
--    NOT changed here: PRD §4.7 gives item_types C/U to owner AND manager, and narrowing the other columns
--    (name, pack_size, pieces_per_load, …) to owner-only needs an owner decision (escalated 2026-11-10).
--    Rows of a plant the caller has no role on pass to RLS (no oracle); service role / postgres not checked.
-- 4. DATA: app.apply_sheet_bin_sizes(plant) sets bin_size = 500 on "Sheet – new" and "Sheet – regular" when
--    still null (an owner-entered value is never overwritten). Run here for the ADB plant (cloud) and from
--    seed.sql for a fresh database (seed runs after migrations).

alter table public.item_types
  add column bin_size integer null,
  add column stock_qty integer null,
  add constraint item_types_bin_size_range check (bin_size between 1 and 5000),
  add constraint item_types_stock_qty_range check (stock_qty between 0 and 10000000);

comment on column public.item_types.bin_size is
  'Owner 2026-11-10: pieces in one full bin, for the finishing entry screen''s "+1 bin" quick-add (sheets: 500). Null = no bin quick-add (e.g. old sheets, variable). 1–5,000. Owner-only edit (app.guard_item_owner_fields).';
comment on column public.item_types.stock_qty is
  'Owner 2026-11-10: pieces of this item the plant owns, for the "more than we own" warning on the finishing entry screen. Null = unknown (no warning). 0–10,000,000. Owner-only edit (app.guard_item_owner_fields).';

grant insert (bin_size, stock_qty), update (bin_size, stock_qty) on public.item_types to authenticated;

create function app.guard_item_owner_fields()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    return new;                                  -- service role / migrations
  end if;
  if not app.has_role(new.plant_id, '{owner,manager,lead,viewer}') then
    return new;                                  -- RLS rejects it; no oracle
  end if;
  if (tg_op = 'INSERT' and (new.bin_size is not null or new.stock_qty is not null))
     or (tg_op = 'UPDATE' and (new.bin_size, new.stock_qty) is distinct from (old.bin_size, old.stock_qty)) then
    if not app.has_role(new.plant_id, '{owner}') then
      raise exception 'NOT_AUTHORIZED' using detail = 'item bin_size / stock_qty: owner only';
    end if;
  end if;
  return new;
end;
$$;
comment on function app.guard_item_owner_fields() is
  'Owner 2026-11-10: BEFORE INSERT / UPDATE OF bin_size, stock_qty on item_types: only an owner of the plant may set or change them (NOT_AUTHORIZED). Rows of a plant the caller has no role on pass to RLS; service role / postgres not checked.';
revoke all on function app.guard_item_owner_fields() from public, anon, authenticated;

create trigger item_types_guard_owner_fields before insert or update of bin_size, stock_qty on public.item_types
  for each row execute function app.guard_item_owner_fields();

-- ── DATA: sheet bins of 500 ──────────────────────────────────────────────
create function app.apply_sheet_bin_sizes(p_plant_id uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_set    int := 0;
  v_result jsonb;
begin
  if p_plant_id is null or not exists (select 1 from public.plants p where p.id = p_plant_id) then
    raise exception 'VALIDATION_FAILED' using detail = 'apply_sheet_bin_sizes: unknown plant';
  end if;
  update public.item_types i
     set bin_size = 500
   where i.plant_id = p_plant_id
     and i.bin_size is null
     and lower(regexp_replace(btrim(i.name), '\s+', ' ', 'g')) in ('sheet – new', 'sheet – regular', 'sheet - new', 'sheet - regular');
  get diagnostics v_set = row_count;
  v_result := jsonb_build_object('set', v_set);
  raise notice 'apply_sheet_bin_sizes(%): %', p_plant_id, v_result;
  return v_result;
end;
$$;
comment on function app.apply_sheet_bin_sizes(uuid) is
  'Owner 2026-11-10, one-shot data change for one plant, shared by migration 20261110141433 (cloud, ADB plant) and seed.sql: bin_size = 500 on the items "Sheet – new" and "Sheet – regular" (case, spaces and – / - ignored) where bin_size is still null; owner-entered values are never overwritten; "Sheet – old" stays null (variable). Idempotent. VALIDATION_FAILED on an unknown plant. Postgres only.';
revoke all on function app.apply_sheet_bin_sizes(uuid) from public, anon, authenticated;

-- The ADB plant (no row on a fresh database: seed.sql calls the function itself).
select app.apply_sheet_bin_sizes(p.id)
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami';
