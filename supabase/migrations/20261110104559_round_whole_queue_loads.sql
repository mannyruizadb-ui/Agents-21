-- Audit 2026-11-10 (whole-load rounding mismatch): the app rounds a load count to whole loads as
-- ceil(round(x, 2)) (src/features/dirtyWork/dirtyWork.ts wholeLoads: Math.ceil(Math.round(x * 100) / 100)),
-- while app.queue_loads_needed used ceil(x). With a 3-decimal factor the two disagreed: 3 baskets ×
-- 0.667 loads/basket = 2.001 loads → the app said 2 loads, the queue needed 3 (and never auto-completed
-- after the 2nd start). The database now rounds the same way: whole loads = ceil(round(to_loads, 2)).
-- Same signature, language, volatility and SECURITY INVOKER as 20261104163713; null stays null.

create or replace function app.queue_loads_needed(p_wash_group_id uuid, p_item_type_id uuid, p_qty numeric, p_unit app.qty_unit)
returns int language sql stable set search_path = '' as $$
  select case when p_unit in ('load', 'basket', 'bin')
              then pg_catalog.ceil(pg_catalog.round(app.to_loads(p_wash_group_id, p_item_type_id, p_qty, p_unit), 2))::int end;
$$;
comment on function app.queue_loads_needed(uuid, uuid, numeric, app.qty_unit) is
  'M2: whole loads a queue item needs = ceil(round(app.to_loads(qty), 2)) for load/basket/bin units (audit 2026-11-10: the app''s wholeLoads rounding, so 3 × 0.667 = 2.001 → 2 loads on both sides); null for piece/pack or a missing factor (never auto-completed). SECURITY INVOKER: caller''s RLS applies.';
