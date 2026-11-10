-- Owner 2026-11-10: every load-out quantity is a piece count ("Sheets 500"), pack items included. The
-- crew types the invoice numbers; the screens no longer say "packs of 10". No data changes: the lines
-- already hold piece counts (e.g. 400 / 280 / 50 sheets per route); only the documented meaning was wrong.

comment on function public.get_load_out_board(uuid, date) is
  'Owner 2026-11-06 read (owner/manager/lead/viewer; definer, role check first): the load-out for p_load_date (default: the next loading morning, plant-local: today before noon, else tomorrow). jsonb {plant_id, load_date, routes[{route_id, name, load_time, loaded, loaded_since, loaded_by_name, lines[{line_id, item_type_id, item_name, item_name_i18n, count_mode, pack_size, special_text, qty, entered_by_name}]}] (only active routes that run on that weekday, by load time), totals[{item_type_id, item_name, item_name_i18n, count_mode, pack_size, qty}] (items only; specials stay per route), server_time}. qty is in PIECES for every item (owner 2026-11-10: typed from the invoice, e.g. 500 sheets; pack_size is informational only). loaded_by_name / entered_by_name: OWNER callers only (null for every other role; null for lines typed before 2026-11-06). Errors: NOT_AUTHORIZED.';
comment on column public.load_out_lines.qty is
  'Pieces for every item (owner 2026-11-10), as typed from the invoice; pack items are NOT in packs. For a special item: the quantity typed.';
