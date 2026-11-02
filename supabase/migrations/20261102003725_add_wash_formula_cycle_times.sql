-- Owner decision 2026-11-02 (A): wash formulas (Milnor programs) carry a cycle time, and the mapping
-- direction is GROUP → FORMULA, because one formula washes MANY wash groups (formula 1 runs black,
-- colored, charcoal, scraper and City & Brito mats plus dust and wet mops).
--
--   * wash_formulas.cycle_minutes: the program's run time in minutes (1–300), null = not known yet.
--     A duration, never a weight.
--   * wash_groups.wash_formula_id: the formula this group is normally washed with (same plant,
--     composite FK). Null = unmapped (owner TODO). Owner/manager writable through the existing
--     wash_groups policies; audited by the existing wash_groups_audit trigger.
--   * wash_formulas.wash_group_id stays (it resolves Accu-Flow rows to a group in
--     app.resolve_group_from_formula), but is only set when the formula maps to EXACTLY ONE group.
--     A formula shared by several groups leaves it null, and a cycle recorded with only that
--     formula stays unmapped (wash_group_id null) until someone picks the group. Accu-Flow is not
--     built (F3 waits for a real export sample).
--
-- No new table, no new policy, no new SECURITY DEFINER code: the FK alone checks the reference, so a
-- foreign formula UUID gives 23503 to every caller (no cross-tenant oracle).

alter table public.wash_formulas
  add column cycle_minutes int
    constraint wash_formulas_cycle_minutes_range check (cycle_minutes between 1 and 300);
comment on column public.wash_formulas.cycle_minutes is
  'Owner 2026-11-02: run time of this washer program in minutes (1–300). Null = not known yet (never guessed).';
comment on column public.wash_formulas.wash_group_id is
  'Accu-Flow resolution only (app.resolve_group_from_formula): set ONLY when this formula washes exactly one wash group; null when it washes several (or is unmapped). The normal mapping is wash_groups.wash_formula_id (group → formula).';
comment on table public.wash_formulas is
  'Washer programs (Milnor formulas; Accu-Flow formula numbers). One formula washes many wash groups: see wash_groups.wash_formula_id. cycle_minutes = program run time.';

alter table public.wash_groups
  add column wash_formula_id uuid,
  add constraint wash_groups_wash_formula_fkey
    foreign key (wash_formula_id, plant_id) references public.wash_formulas(id, plant_id);
create index wash_groups_formula_plant_idx on public.wash_groups (wash_formula_id, plant_id);
comment on column public.wash_groups.wash_formula_id is
  'Owner 2026-11-02: the washer program (formula) this group is normally washed with; several groups share one formula. Same plant (composite FK). Null = unmapped (owner TODO).';

comment on function app.resolve_group_from_formula() is
  '§4.5 BEFORE INSERT/UPDATE on washer_cycles: copies the wash formula''s wash_group_id when wash_group_id is null. That column is set only for a formula that washes exactly one group, so a cycle with a shared formula and no group stays unmapped (null) until a group is chosen.';
