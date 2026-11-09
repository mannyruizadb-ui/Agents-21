-- Setup → Wash groups and Setup → Formulas in the app (owner 2026-11-09, review items 8–9: "edit all that type
-- of stuff in app so this doesn't wait"). The write path is DIRECT table writes, as for the other setup tables
-- (20261103212053_guard_setup_table_edits): RLS + column grants + validation triggers + audit. This migration
-- only closes the gaps found while checking that path; no RPC is added.
--
-- What already holds (unchanged, re-asserted by supabase/tests/224_wash_setup_edits.test.sql):
-- * Column grants on wash_groups cover name, name_i18n, color_hex, category, wash_formula_id, loads_per_basket,
--   loads_per_bin, allow_basket_estimates, allow_bin_estimates, default_estimate_unit, sort_order, active,
--   ships_next_morning, customer_id. No DELETE policy on either table (deactivate / retire instead).
-- * Customer (AA Linen) groups: owner only (app.guard_wash_group_customer, 2026-11-07).
-- * wash_formulas column grants: external_no, name, cycle_minutes, wash_group_id; cycle_minutes 1–300,
--   external_no 1–20 clean chars, unique per plant. Both tables audited (app.audit).
-- * READ is unchanged: owner, manager, lead, viewer and the plant's displays.
--
-- Changes:
-- 1. wash_groups load-factor ceiling: loads_per_basket / loads_per_bin were (0, 1000]; now (0, 20]. The real
--    values are 2–4 loads per container (owner 2026-11-04/05), so 20 leaves 5× headroom and still rejects a
--    slipped decimal (35 for 3.5 passes, 350 does not). Existing data is ≤ 4, so the new CHECK validates.
-- 2. wash_formulas.active (new, default true): there is no DELETE, so a formula added by mistake (or a retired
--    washer program) needs a way out of the pickers. Owner only (column grant + RLS).
--    app.guard_wash_formula_link keeps the link consistent:
--    * a formula cannot be deactivated while an ACTIVE wash group still points to it (VALIDATION_FAILED: move
--      the groups first);
--    * an active wash group cannot be pointed at an inactive formula, nor re-activated while it points to one
--      (VALIDATION_FAILED).
--    Past washer cycles keep their formula (history is untouched; the board still reads its cycle_minutes).
--    Rows of a plant the caller has no role on pass through to RLS (no oracle); service role is validated.
-- 0. OWNER DECISION 2026-11-09: wash groups and wash formulas are OWNER-ONLY setup. INSERT and UPDATE
--    policies on public.wash_groups and public.wash_formulas narrow from {owner,manager} to {owner}: managers
--    (with or without can_edit_load_factors) can no longer add or edit any group (ours or a customer's) or
--    any formula. A manager's UPDATE matches no rows (0, no error); an INSERT fails RLS (42501).
--    memberships.can_edit_load_factors is therefore moot: its only use is app.guard_load_factor_edit on
--    wash_groups (kept: harmless, the owner always passes). No RPC writes either table on a manager's
--    behalf (only the postgres-only data functions app.apply_mat_basket_groups / apply_mat_spanish_names).
-- 3. Sane values for the other owner-typed fields (no column changes; existing data validates):
--    * wash_groups.sort_order within ±100000 (same range as customers.sort_order; seed uses 10…1070);
--    * wash_formulas.name blank is NULL, not '': 1–80 clean characters when present (was 0–80).

-- ── 0. Owner-only writes ──────────────────────────────────────────────────
drop policy wash_groups_insert on public.wash_groups;
drop policy wash_groups_update on public.wash_groups;
create policy wash_groups_insert on public.wash_groups for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner}')));
create policy wash_groups_update on public.wash_groups for update to authenticated
  using ((select app.has_role(plant_id, '{owner}')))
  with check ((select app.has_role(plant_id, '{owner}')));

drop policy wash_formulas_insert on public.wash_formulas;
drop policy wash_formulas_update on public.wash_formulas;
create policy wash_formulas_insert on public.wash_formulas for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner}')));
create policy wash_formulas_update on public.wash_formulas for update to authenticated
  using ((select app.has_role(plant_id, '{owner}')))
  with check ((select app.has_role(plant_id, '{owner}')));

-- ── 1. Load-factor ceiling ────────────────────────────────────────────────
alter table public.wash_groups
  drop constraint wash_groups_loads_per_basket_range,
  drop constraint wash_groups_loads_per_bin_range,
  add constraint wash_groups_loads_per_basket_range check (loads_per_basket > 0 and loads_per_basket <= 20),
  add constraint wash_groups_loads_per_bin_range check (loads_per_bin > 0 and loads_per_bin <= 20),
  add constraint wash_groups_sort_order_range check (sort_order between -100000 and 100000);

-- ── 3. Formula name: 1–80 characters when present ─────────────────────────
alter table public.wash_formulas
  drop constraint wash_formulas_name_check,
  add constraint wash_formulas_name_check check (char_length(name) between 1 and 80 and app.is_clean_text(name));

-- ── 2. Formula active flag + link guard ───────────────────────────────────
alter table public.wash_formulas add column active boolean not null default true;
comment on column public.wash_formulas.active is
  'Owner 2026-11-09: false = retired (hidden from pickers; no deletes). Cannot be set false while an active wash group points to the formula (app.guard_wash_formula_link).';
grant update (active) on public.wash_formulas to authenticated;

create function app.guard_wash_formula_link()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_formula_active boolean;
begin
  if (select auth.uid()) is not null and not app.has_role(new.plant_id, '{owner,manager,lead,viewer}') then
    return new;                                  -- RLS rejects it; no oracle
  end if;
  if tg_table_name = 'wash_formulas' then
    if old.active and not new.active
       and exists (select 1 from public.wash_groups g
                    where g.wash_formula_id = new.id and g.plant_id = new.plant_id and g.active) then
      raise exception 'VALIDATION_FAILED'
        using detail = 'wash_formula: active wash groups still use it; give them another formula first';
    end if;
  elsif tg_table_name = 'wash_groups' then
    if new.active and new.wash_formula_id is not null
       and (tg_op = 'INSERT'
            or new.wash_formula_id is distinct from old.wash_formula_id
            or not old.active) then
      -- FOR SHARE (security review 2026-11-09): conflicts with a concurrent UPDATE of the formula (retire), so
      -- "retire the formula" and "link an active group to it" cannot both commit. Whichever waits re-checks:
      -- a waiting link re-reads the row (now inactive → refused); a waiting retire runs its group check after
      -- the link commits (fresh snapshot per statement → refused). The FK's KEY SHARE alone would not conflict.
      select f.active into v_formula_active
        from public.wash_formulas f
       where f.id = new.wash_formula_id and f.plant_id = new.plant_id
         for share;
      if v_formula_active = false then
        raise exception 'VALIDATION_FAILED' using detail = 'wash_formula_id: that formula is retired (inactive)';
      end if;
    end if;
  end if;
  return new;
end;
$$;
comment on function app.guard_wash_formula_link() is
  'Owner 2026-11-09 (Setup → Formulas): BEFORE UPDATE OF active on wash_formulas rejects retiring a formula an active wash group uses; BEFORE INSERT / UPDATE OF wash_formula_id, active on wash_groups rejects linking an active group to a retired formula (VALIDATION_FAILED), locking the formula row FOR SHARE so a concurrent retire and link cannot both commit. Rows of a plant the caller has no role on pass to RLS; service role is validated.';
revoke all on function app.guard_wash_formula_link() from public, anon, authenticated;

create trigger wash_formulas_guard_link before update of active on public.wash_formulas
  for each row execute function app.guard_wash_formula_link();
create trigger wash_groups_guard_formula_link before insert or update of wash_formula_id, active on public.wash_groups
  for each row execute function app.guard_wash_formula_link();

comment on table public.wash_formulas is
  'Washer programs (Milnor formulas; Accu-Flow formula numbers). One formula washes many wash groups: see wash_groups.wash_formula_id. cycle_minutes = program run time. Setup in the app (owner 2026-11-09): OWNER-ONLY insert and edit of external_no, name, cycle_minutes, active (retire instead of delete); managers read only; audited.';
