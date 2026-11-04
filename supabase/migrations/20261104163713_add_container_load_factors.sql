-- Bins and baskets (owner 2026-11-04, round 3; research/estimate-bins.md). Estimates and rewash queue
-- items can be in loads, baskets or bins. Loads per FULL container are owner estimates, not rules, so
-- every basket / bin conversion is approximate.
--
-- * wash_groups.loads_per_basket / loads_per_bin: loads one full container makes, per wash group
--   (null = no conversion yet: app.to_loads gives null, never a guess).
-- * wash_groups.allow_bin_estimates mirrors allow_basket_estimates: a group accepts estimates in a
--   container only when its factor is set (CHECK), and its default estimate unit must be allowed.
-- * wash_groups.baskets_per_load (the old inverse factor) is DEPRECATED: copied into loads_per_basket
--   (= 1 / baskets_per_load), no longer read by app.to_loads, and no longer client-editable. The column
--   is kept (no column holding data is dropped without an owner decision); drop it in a later
--   migration once confirmed.
-- * app.to_loads stays the single conversion function: basket = qty × loads_per_basket, bin = qty ×
--   loads_per_bin.

-- ── wash_groups ───────────────────────────────────────────────────────────
alter table public.wash_groups
  add column loads_per_basket numeric(7,3)
    constraint wash_groups_loads_per_basket_range check (loads_per_basket > 0 and loads_per_basket <= 1000),
  add column loads_per_bin numeric(7,3)
    constraint wash_groups_loads_per_bin_range check (loads_per_bin > 0 and loads_per_bin <= 1000),
  add column allow_bin_estimates boolean not null default false;
comment on column public.wash_groups.loads_per_basket is
  'Owner 2026-11-04: washer loads one FULL basket of this group makes (approximate). Null = no conversion (basket quantities convert to null).';
comment on column public.wash_groups.loads_per_bin is
  'Owner 2026-11-04: washer loads one FULL bin of this group makes (approximate). Null = no conversion (bin quantities convert to null).';
comment on column public.wash_groups.allow_bin_estimates is
  'Owner 2026-11-04: estimates for this group may be entered in bins (requires loads_per_bin).';
comment on column public.wash_groups.allow_basket_estimates is
  'Estimates for this group may be entered in baskets (requires loads_per_basket since 2026-11-04).';
comment on column public.wash_groups.baskets_per_load is
  'DEPRECATED 2026-11-04: replaced by loads_per_basket (= 1 / baskets_per_load, copied once). Not read by app.to_loads and not client-editable; to be dropped after owner confirmation.';

-- Carry existing basket factors over (no-op where none is set, e.g. the cloud seed).
update public.wash_groups g
   set loads_per_basket = greatest(round(1 / g.baskets_per_load, 3), 0.001)
 where g.baskets_per_load is not null and g.loads_per_basket is null;

-- Guards: the old ones named baskets_per_load and only knew load/basket.
alter table public.wash_groups
  drop constraint wash_groups_check,                              -- allow_basket_estimates → baskets_per_load
  drop constraint wash_groups_check1,                             -- default basket → allow_basket_estimates
  drop constraint wash_groups_default_estimate_unit_check,        -- load | basket
  add constraint wash_groups_basket_needs_factor check (not allow_basket_estimates or loads_per_basket is not null),
  add constraint wash_groups_bin_needs_factor check (not allow_bin_estimates or loads_per_bin is not null),
  add constraint wash_groups_default_estimate_unit_check check (default_estimate_unit in ('load', 'basket', 'bin')),
  add constraint wash_groups_default_unit_allowed check (
    (default_estimate_unit <> 'basket' or allow_basket_estimates)
    and (default_estimate_unit <> 'bin' or allow_bin_estimates));

comment on table public.wash_groups is
  'Owner 2026-11-01: what may share a washer. Washroom data (estimates, queue, washer cycles, formulas) is per wash group; finished goods are per item. loads_per_basket / loads_per_bin convert container quantities (owner 2026-11-04; null = no conversion).';

-- Setup screens: the new factors are editable; the deprecated one is not.
revoke update (baskets_per_load) on public.wash_groups from authenticated;
grant update (loads_per_basket, loads_per_bin, allow_bin_estimates) on public.wash_groups to authenticated;

-- ── soil_estimates / queue_items: + bin ───────────────────────────────────
-- ALTER TABLE ... ADD CONSTRAINT does not fire the append-only row triggers.
alter table public.soil_estimates
  drop constraint soil_estimates_unit_check,
  add constraint soil_estimates_unit_check check (unit in ('load', 'basket', 'bin'));
alter table public.queue_items
  drop constraint queue_items_piece_pack_need_item,
  add constraint queue_items_piece_pack_need_item check (unit in ('load', 'basket', 'bin') or item_type_id is not null);

-- ── §4.6 conversion: still the single source of truth ─────────────────────
create or replace function app.to_loads(p_wash_group_id uuid, p_item_type_id uuid, p_qty numeric, p_unit app.qty_unit)
returns numeric language sql stable set search_path = '' as $$
  select case p_unit
           when 'load'   then p_qty
           when 'basket' then p_qty * g.loads_per_basket
           when 'bin'    then p_qty * g.loads_per_bin
           when 'piece'  then p_qty / i.pieces_per_load
           when 'pack'   then p_qty * i.pack_size / i.pieces_per_load
         end
    from public.wash_groups g
    left join public.item_types i on i.id = p_item_type_id and i.wash_group_id = g.id
   where g.id = coalesce(p_wash_group_id,
                         (select it.wash_group_id from public.item_types it where it.id = p_item_type_id))
     and (p_item_type_id is null or i.id is not null);
$$;
comment on function app.to_loads(uuid, uuid, numeric, app.qty_unit) is
  '§4.6 Converts qty in unit to standard wash loads. load = qty; basket = qty × wash group loads_per_basket; bin = qty × wash group loads_per_bin (owner 2026-11-04); piece = qty / item pieces_per_load; pack = qty × item pack_size / item pieces_per_load. Null when a factor, the group or the item is missing (or the item is not in the group): never a guess. basket, bin, piece and pack are approximate.';

create or replace function app.queue_loads_needed(p_wash_group_id uuid, p_item_type_id uuid, p_qty numeric, p_unit app.qty_unit)
returns int language sql stable set search_path = '' as $$
  select case when p_unit in ('load', 'basket', 'bin')
              then pg_catalog.ceil(app.to_loads(p_wash_group_id, p_item_type_id, p_qty, p_unit))::int end;
$$;
comment on function app.queue_loads_needed(uuid, uuid, numeric, app.qty_unit) is
  'M2: whole loads a queue item needs = ceil(app.to_loads(qty)) for load/basket/bin units; null for piece/pack or a missing factor (never auto-completed). SECURITY INVOKER: caller''s RLS applies.';

-- ── estimate unit guards ──────────────────────────────────────────────────
create or replace function app.check_estimate_unit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- Security M2: no cross-tenant oracle; RLS rejects rows on plants the caller has no role on.
  if (select auth.uid()) is not null and not app.has_role(new.plant_id, '{owner,manager,lead,viewer}') then
    return new;
  end if;
  -- Security H1: look the group up in the row's own plant only. Not found (another plant's or a
  -- missing group) → the composite FK reports it, whatever that foreign group allows.
  if new.unit = 'basket' and exists (
       select 1 from public.wash_groups g
        where g.id = new.wash_group_id and g.plant_id = new.plant_id and not g.allow_basket_estimates) then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: basket estimates are not allowed for this wash group';
  end if;
  if new.unit = 'bin' and exists (
       select 1 from public.wash_groups g
        where g.id = new.wash_group_id and g.plant_id = new.plant_id and not g.allow_bin_estimates) then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: bin estimates are not allowed for this wash group';
  end if;
  return new;
end;
$$;
comment on function app.check_estimate_unit() is
  '§4.5 BEFORE INSERT on soil_estimates: rejects unit basket / bin when the row''s wash group (looked up in the row''s plant only, H1) does not allow basket / bin estimates (VALIDATION_FAILED); a foreign or missing group is left to the FK (23503).';

create or replace function public.record_soil_estimate(
  p_wash_group_id    uuid,
  p_qty              numeric,
  p_unit             app.qty_unit,
  p_client_id        uuid,
  p_staff_session_id uuid,
  p_note             text default null)
returns public.soil_estimates language plpgsql volatile security definer set search_path = '' as $$
declare
  v_g     record;
  v_row   public.soil_estimates;
  v_note  text;
  v_staff uuid;
begin
  select g.id, g.org_id, g.plant_id, g.active, g.allow_basket_estimates, g.allow_bin_estimates into v_g
    from public.wash_groups g where g.id = p_wash_group_id;
  if v_g.id is null or not app.has_role(v_g.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'record_soil_estimate requires owner or manager on the wash group''s plant';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  select e.* into v_row from public.soil_estimates e where e.client_id = p_client_id;
  if v_row.id is not null then
    if v_row.plant_id = v_g.plant_id then
      return v_row;
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  if not v_g.active then
    raise exception 'VALIDATION_FAILED' using detail = 'wash_group_id: the wash group is inactive';
  end if;
  perform app.check_qty(p_qty, 0, 10000, 'qty');
  if p_unit is null or p_unit not in ('load', 'basket', 'bin') then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: load, basket or bin';
  end if;
  if p_unit = 'basket' and not v_g.allow_basket_estimates then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: basket estimates are not allowed for this wash group';
  end if;
  if p_unit = 'bin' and not v_g.allow_bin_estimates then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: bin estimates are not allowed for this wash group';
  end if;
  v_note := app.clean_note(p_note, 280, 'note');
  v_staff := app.use_staff_session(p_staff_session_id, v_g.plant_id);

  insert into public.soil_estimates as e (org_id, plant_id, wash_group_id, qty, unit, note, entered_by, staff_id, client_id)
  values (v_g.org_id, v_g.plant_id, v_g.id, p_qty, p_unit, v_note, (select auth.uid()), v_staff, p_client_id)
  on conflict (client_id) do nothing
  returning e.* into v_row;
  if v_row.id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';   -- concurrent retry; the client refetches
  end if;
  return v_row;
end;
$$;
comment on function public.record_soil_estimate(uuid, numeric, app.qty_unit, uuid, uuid, text) is
  'B1 RPC (owner/manager + staff session, A8): appends a soil estimate for a wash group (never updates; 0 = cleared). qty 0–10,000 (2 decimals; e.g. 2.75 bins) in load, or basket / bin when the group allows it (owner 2026-11-04); note ≤ 280. Idempotent on p_client_id (returns the existing row, even after the single-use session is spent). Returns the soil_estimates row. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, STAFF_SESSION_REQUIRED.';
