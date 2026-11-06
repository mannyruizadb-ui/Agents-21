-- In-app setup (owner 2026-11-03): the owner and managers edit plant data themselves through DIRECT
-- table writes, guarded by RLS (unchanged: owner/manager C U on these tables), the audit triggers and
-- the validation triggers. ADR 001 (RPC-only writes) is about operational tables, not setup tables.
-- This migration closes the unsafe edits that direct writes allowed:
--
-- 1. Column-level UPDATE grants. Clients could UPDATE every column, including id, org_id, plant_id and
--    created_at/updated_at. Now only the editable columns are granted, so a row can never be moved to
--    another plant or org, and ids never change (42501). INSERT is unchanged (RLS with check).
-- 2. "Deactivate + create new" instead of edits that would rewrite history:
--    * machines.kind / machines.area_id cannot change once a washer cycle or a queue item references
--      the machine (VALIDATION_FAILED; the queue FK already enforced this with 23503);
--    * areas.kind cannot change once anything is recorded in the area (machines, shifts, queue items,
--      washer cycles, finished goods): the write RPCs rely on the kind (washroom vs finishing);
--    * item_types.count_mode cannot change once finished goods exist for the item (unit ↔ pack would
--      make past entries mean something else).
--    These guards fire only on rows the caller may already update (RLS USING runs first), so they
--    reveal nothing about other tenants.
-- 3. Shift edits regenerate future instances at once. A client INSERT of an active shift, or an
--    UPDATE that changes start/end/days/active, runs app.generate_shift_instances(plant, 14) in the same
--    transaction (idempotent: only FUTURE instances that nothing references change; inactive shifts'
--    and removed weekdays' unreferenced future instances are marked skipped, never deleted). If a
--    referenced future instance (e.g. an entry recorded for "next shift") makes the new times collide,
--    the edit is rejected (VALIDATION_FAILED) instead of half-applied. Edits by the service role /
--    SQL (auth.uid() null) are left to the nightly pg_cron run or an explicit generate call.

-- ── 1. Column-level UPDATE grants ─────────────────────────────────────────
-- anon keeps its (unused) table grants: it has no policy, so RLS already denies it every row.
revoke update on public.areas, public.stations, public.machines, public.item_types,
  public.wash_groups, public.wash_formulas, public.shifts from authenticated;

grant update (name, kind, sort_order, active) on public.areas to authenticated;
grant update (name, kind, active) on public.stations to authenticated;
grant update (name, kind, area_id, vendor, model, external_ref, active, load_factor) on public.machines to authenticated;
grant update (name, name_i18n, category, count_mode, pack_size, pieces_per_load, pieces_per_load_source,
              color_hex, sort_order, active, wash_group_id) on public.item_types to authenticated;
grant update (name, name_i18n, color_hex, default_estimate_unit, allow_basket_estimates, baskets_per_load,
              sort_order, active, wash_formula_id, ships_next_morning) on public.wash_groups to authenticated;
grant update (external_no, name, cycle_minutes, wash_group_id) on public.wash_formulas to authenticated;
grant update (name, start_local, end_local, days_of_week, active) on public.shifts to authenticated;

-- ── 2. History guards ─────────────────────────────────────────────────────
create function app.guard_setup_edit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'machines' then
    if (new.kind, new.area_id) is distinct from (old.kind, old.area_id)
       and (exists (select 1 from public.washer_cycles w where w.machine_id = old.id and w.plant_id = old.plant_id)
            or exists (select 1 from public.queue_items q where q.assigned_machine_id = old.id and q.plant_id = old.plant_id)) then
      raise exception 'VALIDATION_FAILED' using detail = 'machine: in use, so its kind and area are fixed. Deactivate it and add a new machine';
    end if;
  elsif tg_table_name = 'areas' then
    if new.kind is distinct from old.kind
       and (exists (select 1 from public.machines m where m.area_id = old.id and m.plant_id = old.plant_id)
            or exists (select 1 from public.shifts s where s.area_id = old.id and s.plant_id = old.plant_id)
            or exists (select 1 from public.queue_items q where q.area_id = old.id and q.plant_id = old.plant_id)
            or exists (select 1 from public.washer_cycles w where w.area_id = old.id and w.plant_id = old.plant_id)
            or exists (select 1 from public.finished_goods_entries f where f.area_id = old.id and f.plant_id = old.plant_id)) then
      raise exception 'VALIDATION_FAILED' using detail = 'area: in use, so its kind is fixed. Deactivate it and add a new area';
    end if;
  elsif tg_table_name = 'item_types' then
    if new.count_mode is distinct from old.count_mode
       and exists (select 1 from public.finished_goods_entries f where f.item_type_id = old.id and f.plant_id = old.plant_id) then
      raise exception 'VALIDATION_FAILED' using detail = 'item: finished goods exist, so its count mode is fixed. Deactivate it and add a new item';
    end if;
  end if;
  return new;
end;
$$;
comment on function app.guard_setup_edit() is
  'BEFORE UPDATE guard on machines (kind, area_id), areas (kind) and item_types (count_mode): rejects the change once history references the row (VALIDATION_FAILED: deactivate + create new). Fires only on rows the caller may update (RLS USING first), lookups filtered by the row''s plant.';
revoke all on function app.guard_setup_edit() from public, anon, authenticated;

create trigger machines_guard_edit before update of kind, area_id on public.machines
  for each row execute function app.guard_setup_edit();
create trigger areas_guard_edit before update of kind on public.areas
  for each row execute function app.guard_setup_edit();
create trigger item_types_guard_edit before update of count_mode on public.item_types
  for each row execute function app.guard_setup_edit();

-- ── 3. Shift edits regenerate future instances ────────────────────────────
create function app.regenerate_after_shift_edit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    return null;   -- service role / SQL: nightly pg_cron or an explicit generate call
  end if;
  if tg_op = 'INSERT' and not new.active then
    return null;   -- nothing to generate
  end if;
  begin
    perform app.generate_shift_instances(new.plant_id, 14);
  exception when exclusion_violation then
    raise exception 'VALIDATION_FAILED'
      using detail = 'shift: the new hours collide with a future shift that already has entries; change it after that shift, or skip that shift first';
  end;
  return null;
end;
$$;
comment on function app.regenerate_after_shift_edit() is
  'AFTER INSERT, and AFTER UPDATE that changes start_local, end_local, days_of_week or active, on shifts, for client edits (auth.uid() not null): app.generate_shift_instances(plant, 14) in the same transaction, so future unreferenced instances follow the edit at once. A collision with a referenced future instance rejects the edit (VALIDATION_FAILED).';
revoke all on function app.regenerate_after_shift_edit() from public, anon, authenticated;

create trigger shifts_regenerate_instances_insert
  after insert on public.shifts
  for each row
  execute function app.regenerate_after_shift_edit();
create trigger shifts_regenerate_instances_update
  after update of start_local, end_local, days_of_week, active on public.shifts
  for each row
  when ((old.start_local, old.end_local, old.days_of_week, old.active)
        is distinct from (new.start_local, new.end_local, new.days_of_week, new.active))
  execute function app.regenerate_after_shift_edit();
