-- Owner 2026-11-04 (round 3): two containers in the washroom. BINS (tall, 5–6 ft; mostly linen) and
-- BASKETS (half the height, longer; mats, sometimes linen). Estimates and rewash queue items can be
-- in loads, baskets or bins. Still no weight units: ADB has no scale.
--
-- Its own migration: a new enum value cannot be used in the transaction that adds it, and the next
-- migrations put 'bin' into CHECK constraints.
alter type app.qty_unit add value if not exists 'bin' after 'basket';
comment on type app.qty_unit is
  'Quantity units (no weight: ADB has no scale). load = standard wash load; basket / bin = a full container (owner 2026-11-04; converted with wash_groups.loads_per_basket / loads_per_bin, approximate); piece / pack = finished goods counts.';
