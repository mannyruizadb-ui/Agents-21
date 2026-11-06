-- Owner decision 2026-11-04 ("no names anywhere") + security re-review note 4: who entered,
-- created, updated or voided an operational row is STORED (A8 attribution, audit) but no longer
-- SELECTable by clients. Table-wide SELECT is replaced with column-level SELECT on every other
-- column. Definer RPCs (which run as the owner) and the security_invoker views are unaffected: no
-- view selects these columns (checked: queue_board, current_soil_estimates, washroom_by_shift,
-- finished_by_shift, daily_reconciliation). Realtime filters out columns a role cannot select.
--
-- Hidden from authenticated (and anon loses every privilege on these tables, security L3):
--   soil_estimates          entered_by, staff_id
--   finished_goods_entries  entered_by, staff_id, voided_by
--   washer_cycles           entered_by, staff_id, voided_by
--   queue_items             created_by, updated_by, updated_by_staff_id
--   machine_status_events   reason, reason_code (in addition to entered_by): lead and viewer must not
--                           read the free-text reason; owner and manager get it from
--                           get_machine_status / get_washroom_board, which already hide it per role.
-- voided_by / updated_by / updated_by_staff_id go beyond the listed columns for the same reason.

revoke all on public.soil_estimates, public.finished_goods_entries, public.washer_cycles,
              public.queue_items, public.machine_status_events from anon, authenticated;

grant select (id, org_id, plant_id, qty, unit, note, entered_at, client_id, wash_group_id)
  on public.soil_estimates to authenticated;
grant select (id, org_id, plant_id, area_id, station_id, shift_instance_id, item_type_id, queue_item_id, packs,
              pack_size_used, loose_pieces, pieces, occurred_at, note, source, client_id, voided_at, void_reason,
              created_at, wash_group_id, production_date)
  on public.finished_goods_entries to authenticated;
grant select (id, org_id, plant_id, area_id, machine_id, wash_formula_id, shift_instance_id, started_at, ended_at,
              load_count, source, external_id, import_batch_id, raw, client_id, created_at, wash_group_id,
              load_factor_used, is_rewash, queue_item_id, voided_at, void_reason, production_date)
  on public.washer_cycles to authenticated;
grant select (id, org_id, plant_id, area_id, item_type_id, qty, unit, position, is_rush, status, note, version,
              created_at, updated_at, started_at, completed_at, client_id, wash_group_id, assigned_machine_id,
              assigned_machine_kind, is_rewash, loads_started)
  on public.queue_items to authenticated;
grant select (id, seq, org_id, plant_id, machine_id, status, occurred_at, client_id, created_at)
  on public.machine_status_events to authenticated;
