-- Owner 2026-11-05: more machine kinds (plant utilities and finishing machines). Their own migration:
-- a new enum value cannot be used in the transaction that adds it.
alter type app.machine_kind add value if not exists 'wrapper' after 'folder';
alter type app.machine_kind add value if not exists 'utility' after 'wrapper';
comment on type app.machine_kind is
  'Machine kinds: washer (taps, queue assignment, washer board), dryer, ironer, folder, wrapper (wrapping machine), utility (plant utilities: compressor, soap machine, boiler, water pump), other. Only washers take start-taps and queue assignments.';
