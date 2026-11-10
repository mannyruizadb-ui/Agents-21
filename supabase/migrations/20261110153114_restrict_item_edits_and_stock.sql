-- Owner decisions 2026-11-10 on items (Setup → Items and the finishing entry screen).
--
-- 1. ITEM EDITS ARE OWNER-ONLY. The item_types INSERT and UPDATE policies narrow from {owner,manager} to
--    {owner} (PRD §4.7 item_types C/U was owner + manager; the owner changed it: names, pack sizes, colours,
--    everything). Same pattern as wash groups / formulas (20261109215626_extend_wash_setup_edits): a
--    manager's UPDATE matches no rows (0, no error); an INSERT fails RLS (42501). Lead, viewer, display and
--    anon were already denied. No RPC writes item_types on a manager's behalf (only the postgres-only data
--    functions app.apply_*). app.guard_item_owner_fields (bin_size, stock_qty) is kept: now redundant for
--    clients, harmless.
--
-- 2. STOCK IS OWNER-ONLY TO READ. item_types.stock_qty (pieces the plant owns) is no longer selectable by
--    the authenticated role at all: table-level SELECT is replaced by column-level SELECT on every OTHER
--    column. Consequences:
--    * PostgREST `select=*` on item_types now fails (42501) for EVERY signed-in user: clients must list
--      columns (they already do). A column added to item_types later is not readable by clients until it is
--      granted here explicitly (deny-by-default).
--    * Managers, leads, viewers and displays cannot read stock_qty in any way. No view, RPC or realtime
--      channel returns it (checked: queue_board and the board RPCs select named columns; item_types is not in
--      the realtime publication; audit_log, whose item_types images do carry stock_qty, is owner-only).
--    * The owner reads it through public.get_item_stock(plant) (definer, owner of the plant only).
--    * The owner WRITES it as before: column INSERT/UPDATE grants on stock_qty are unchanged, and
--      PostgREST `.update({stock_qty})` with the default `Prefer: return=minimal` (supabase-js: no .select())
--      needs no SELECT on stock_qty. `.update(...).select('…stock_qty…')` or `select=*` would fail (42501);
--      returning a column list WITHOUT stock_qty works.
--    * The finishing screen's "more than we own" check runs through
--      public.finished_goods_over_stock(item, total_after) → boolean (owner or manager of the item's plant),
--      so a manager learns only over / not over, never the number. Note: repeated calls with different
--      totals can narrow the number down (binary search); accepted as the owner's chosen trade-off, since a
--      manager needs the warning and the function answers only for items of their own plant.
--    get_finished_goods_shift never returned stock (asserted in supabase/tests/231).

-- ── 1. Owner-only item edits ──────────────────────────────────────────────
drop policy item_types_insert on public.item_types;
drop policy item_types_update on public.item_types;
create policy item_types_insert on public.item_types for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner}')));
create policy item_types_update on public.item_types for update to authenticated
  using ((select app.has_role(plant_id, '{owner}')))
  with check ((select app.has_role(plant_id, '{owner}')));

-- ── 2. stock_qty: no client SELECT ────────────────────────────────────────
revoke select on public.item_types from authenticated, anon;
revoke select (stock_qty) on public.item_types from authenticated, anon;
grant select (id, org_id, plant_id, name, name_i18n, category, count_mode, pack_size, pieces_per_load,
              pieces_per_load_source, color_hex, sort_order, active, created_at, updated_at, wash_group_id,
              washed, bin_size)
  on public.item_types to authenticated;

comment on table public.item_types is
  'Catalog items (PRD §4.4). Owner 2026-11-10: insert and edit are OWNER-ONLY (RLS); everyone with a role on the plant (and its displays) reads them, EXCEPT stock_qty: clients have column-level SELECT on every other column (no select=*; grant new columns explicitly). Owner reads stock via get_item_stock(plant); the over-stock warning via finished_goods_over_stock(item, total).';
comment on column public.item_types.stock_qty is
  'Owner 2026-11-10: pieces of this item the plant owns, for the "more than we own" warning on the finishing entry screen. Null = unknown (no warning). 0–10,000,000. Owner-only edit (RLS + app.guard_item_owner_fields) and OWNER-ONLY read: not selectable by clients; read via public.get_item_stock(plant); managers get only public.finished_goods_over_stock(item, total) → boolean.';

-- ── 2a. Owner read of stock ───────────────────────────────────────────────
create function public.get_item_stock(p_plant_id uuid)
returns table (item_type_id uuid, stock_qty integer)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_plant_id is null or not app.has_role(p_plant_id, '{owner}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_item_stock requires owner on the plant';
  end if;
  return query
  select i.id, i.stock_qty
    from public.item_types i
   where i.plant_id = p_plant_id
   order by i.sort_order, i.name, i.id;
end;
$$;
comment on function public.get_item_stock(uuid) is
  'Owner 2026-11-10 (stock is owner-only): every item of the plant (active or not) with its stock_qty (null = unknown), by sort_order, name. OWNER of the plant only (definer, role check first); anyone else, an unknown plant or another tenant → NOT_AUTHORIZED. Writes stay direct: PATCH item_types {stock_qty} with return=minimal.';
revoke all on function public.get_item_stock(uuid) from public, anon, authenticated;
grant execute on function public.get_item_stock(uuid) to authenticated;

-- ── 2b. Over-stock check without the number ───────────────────────────────
create function public.finished_goods_over_stock(p_item_type_id uuid, p_total_after integer)
returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_item record;
begin
  select i.id, i.plant_id, i.stock_qty into v_item from public.item_types i where i.id = p_item_type_id;
  if v_item.id is null or not app.has_role(v_item.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'finished_goods_over_stock requires owner or manager on the item''s plant';
  end if;
  if p_total_after is null or p_total_after < 0 then
    raise exception 'VALIDATION_FAILED' using detail = 'total_after: a whole number of pieces, 0 or more';
  end if;
  return v_item.stock_qty is not null and p_total_after > v_item.stock_qty;
end;
$$;
comment on function public.finished_goods_over_stock(uuid, integer) is
  'Owner 2026-11-10, finishing entry screen "more than we own" warning without revealing stock: true when the item''s stock_qty is set and p_total_after (pieces, the shift total including the entry being typed) is greater than it; false when it is not, or when stock is unknown (null). Owner or manager of the item''s plant (definer, role check first); lead, viewer, display, another tenant or an unknown item → NOT_AUTHORIZED; null or negative total → VALIDATION_FAILED.';
revoke all on function public.finished_goods_over_stock(uuid, integer) from public, anon, authenticated;
grant execute on function public.finished_goods_over_stock(uuid, integer) to authenticated;
