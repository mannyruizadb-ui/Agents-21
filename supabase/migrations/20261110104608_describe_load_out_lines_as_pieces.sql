-- Owner 2026-11-10: every load-out quantity is a PIECE count for every item (pack items included), typed
-- from the invoice. 20261110020639 fixed get_load_out_board and load_out_lines.qty; the table comment and
-- set_load_out_line still said "packs for pack items". Comments only; no data or behaviour changes.

comment on table public.load_out_lines is
  'Owner 2026-11-06: the daily load sheet: per load date (the morning the trucks load) and route, an item with qty in PIECES (owner 2026-11-10: every item, pack items included, as typed from the invoice; never packs) or a special free-text line with a qty. qty 0 = not needed. Written only by set_load_out_line / copy_load_out_from.';
comment on function public.set_load_out_line(uuid, date, uuid, int, uuid, text) is
  'Owner 2026-11-06 RPC (owner, or a manager granted can_enter_load_out; definer, permission first): sets one load-out line for p_load_date (plant-local; 7 days back to 30 ahead) and p_route_id (an active route that runs on that weekday): either p_item_type_id (active item; p_qty in PIECES for every item, pack items included, owner 2026-11-10: typed from the invoice, never packs) or p_special_text (1–80 chars) with p_qty (0–100,000; 0 = not needed). Upserts (same date + route + item/text) and records the caller as entered_by (returned as null). Returns the line. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
