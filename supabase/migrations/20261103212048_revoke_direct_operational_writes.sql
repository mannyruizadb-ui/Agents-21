-- M2 (ADR 001 option B, D8): the write RPCs now exist, so the M1 direct client write paths on the
-- operational tables are removed. From here the ONLY client write paths are:
--   queue_items            create_queue_item, reorder_queue_item, update_queue_item, cancel_queue_item,
--                          set_queue_item_status, start_washer_load / undo_washer_load (progress)
--   soil_estimates         record_soil_estimate (name + PIN)
--   washer_cycles          start_washer_load, undo_washer_load (station taps, no PIN)
--   finished_goods_entries record_finished_goods (name + PIN), void_finished_goods
-- Security carry-forward: "M2 must revoke update on washer_cycles; corrections are void + re-enter".
-- Both layers are closed: the INSERT/UPDATE policies are dropped (RLS deny-by-default) and the table
-- privileges are revoked, so a direct write fails with 42501 before any trigger runs (no trigger can
-- become an oracle). SELECT policies and grants are unchanged; Realtime keeps working.
-- The service role (Edge Functions, a future Accu-Flow import) keeps its privileges.

drop policy soil_estimates_insert on public.soil_estimates;
drop policy queue_items_insert on public.queue_items;
drop policy queue_items_update on public.queue_items;
drop policy fge_insert on public.finished_goods_entries;
drop policy washer_cycles_insert on public.washer_cycles;

revoke insert, update, delete, truncate on public.soil_estimates, public.queue_items,
  public.finished_goods_entries, public.washer_cycles from anon, authenticated;

comment on table public.queue_items is
  'C1–C4 work queue. Client writes only through the queue RPCs and start_washer_load/undo_washer_load (M2; no direct INSERT/UPDATE). Cancelled, never deleted.';
comment on table public.soil_estimates is
  'B1 append-only soil estimates per wash group. Client writes only through record_soil_estimate (name + PIN, M2).';
comment on table public.washer_cycles is
  'F1 washer loads. Client writes only through start_washer_load / undo_washer_load (M2); imports use the service role. Corrections are void + re-enter; never deleted or updated by clients.';
comment on table public.finished_goods_entries is
  'E1 finished goods. Client writes only through record_finished_goods (name + PIN) and void_finished_goods (M2). Voided, never deleted.';
