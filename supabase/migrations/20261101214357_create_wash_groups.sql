-- Owner decision 2026-11-01: the washroom works by WASH GROUP, finishing counts ITEMS.
-- A wash group is what may share a washer (Black mats, Colored mats, Napkins – Red, …). Every item
-- belongs to exactly one wash group. Washroom-side data is per wash group: soil estimates, the work
-- queue (and so the TVs), washer cycles and the wash-formula mapping. Finished goods stay per item.
-- Reconciliation is per production day per wash group: standard_loads washed vs finished loads
-- ≈ Σ over the group's items of pieces / pieces_per_load.
--
-- Measurement model (unchanged rules, new homes):
--   * estimate units and baskets_per_load move from item_types to wash_groups (estimates are per group);
--   * item_types.pieces_per_load stays: pieces of that item in one full load of only that item in a standard
--     washer (load_factor 1.00);
--   * app.to_loads() stays the single conversion function. It now takes (wash_group_id, item_type_id,
--     qty, unit): load/basket convert through the group, piece/pack through the item. Missing factor → null.
--
-- The cloud project is still empty (nothing pushed), so item_type_id is replaced outright on
-- soil_estimates, washer_cycles and wash_formulas, and wash_group_id is added NOT NULL without a
-- backfill. Deviation: queue_items keeps an OPTIONAL item_type_id (must belong to the row's group) so a
-- finishing-area queue item can still be counted in pieces/packs of one item and C4 completion can
-- create a finished-goods row; piece/pack queue units require it.
--
-- History is snapshotted at insert (meta decision, architect N1): finished_goods_entries.wash_group_id
-- (the item's group when entered) and washer_cycles.load_factor_used (the machine's factor when run).
-- Moving an item to another group, or editing a machine's load_factor, never rewrites past reports.
--
-- Security H1: every SECURITY DEFINER validation trigger looks referenced rows up WITHIN new.plant_id.
-- A reference to another plant's row is "not found" and is left to the composite FK (23503), so a
-- caller on their own plant gets the same answer for any foreign UUID (no cross-tenant oracle).

-- ── 0. Drop what depends on the columns being replaced ────────────────────
drop view public.daily_reconciliation;
drop view public.finished_by_shift;
drop view public.washroom_by_shift;
drop view public.queue_board;
drop view public.current_soil_estimates;
drop function app.to_loads(uuid, numeric, app.qty_unit);

-- ── 1. wash_groups (A2) ───────────────────────────────────────────────────
-- §4.7 (same matrix as item_types): owner/manager R C U; lead, viewer, display (own plant, D13) R.
create table public.wash_groups (
  id                     uuid primary key default gen_random_uuid(),
  org_id                 uuid not null,
  plant_id               uuid not null,
  name                   text not null check (char_length(name) between 1 and 60 and app.is_clean_text(name)),
  name_i18n              jsonb not null default '{}'::jsonb check (jsonb_typeof(name_i18n) = 'object'),
  color_hex              text not null default '#64748B' check (color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  default_estimate_unit  app.qty_unit not null default 'load'
                         check (default_estimate_unit in ('load','basket')),
  allow_basket_estimates boolean not null default false,
  baskets_per_load       numeric(8,3) check (baskets_per_load > 0),
  sort_order             int not null default 0,
  active                 boolean not null default true,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  unique (id, plant_id),
  unique (plant_id, name),
  check (not allow_basket_estimates or baskets_per_load is not null),
  check (default_estimate_unit <> 'basket' or allow_basket_estimates)
);
alter table public.wash_groups enable row level security;
create index wash_groups_plant_org_idx on public.wash_groups (plant_id, org_id);
comment on table public.wash_groups is
  'Owner 2026-11-01: what may share a washer. Washroom data (estimates, queue, washer cycles, formulas) is per wash group; finished goods are per item. baskets_per_load converts basket estimates (null = no conversion).';

create trigger wash_groups_touch_updated_at before update on public.wash_groups
  for each row execute function app.touch_updated_at();
create trigger wash_groups_check_languages before insert or update of name_i18n, plant_id on public.wash_groups
  for each row execute function app.check_languages();
create trigger wash_groups_audit after insert or update on public.wash_groups
  for each row execute function app.audit();

create policy wash_groups_select on public.wash_groups for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')) or (select app.is_display(plant_id)));
create policy wash_groups_insert on public.wash_groups for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager}')));
create policy wash_groups_update on public.wash_groups for update to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')))
  with check ((select app.has_role(plant_id, '{owner,manager}')));

-- ── 2. item_types: belongs to one wash group; estimate settings move to the group ──
-- Dropping the estimate columns also drops their CHECKs (basket needs factor, basket default).
alter table public.item_types
  drop column default_estimate_unit,
  drop column allow_basket_estimates,
  drop column baskets_per_load,
  add column wash_group_id uuid not null,
  add foreign key (wash_group_id, plant_id) references public.wash_groups(id, plant_id);
create index item_types_group_plant_idx on public.item_types (wash_group_id, plant_id);
comment on column public.item_types.wash_group_id is
  'Owner 2026-11-01: the wash group this item washes with (same plant, composite FK). Reports read it at report time, so moving an item to another group moves its history too (audited).';
comment on column public.item_types.pieces_per_load is
  'Approximate pieces of this item in one full load of only this item in a standard washer (load_factor 1.00). Null = no conversion yet (never guessed).';

-- ── 3. wash_formulas: a formula maps to a wash group (F2) ─────────────────
alter table public.wash_formulas
  drop column item_type_id,
  add column wash_group_id uuid,                                    -- null = unmapped / mixed
  add foreign key (wash_group_id, plant_id) references public.wash_groups(id, plant_id);
create index wash_formulas_group_plant_idx on public.wash_formulas (wash_group_id, plant_id);

-- ── 4. soil_estimates: per wash group (B1) ────────────────────────────────
-- ALTER TABLE does not fire the append-only row triggers; the table is empty in every environment.
alter table public.soil_estimates
  drop column item_type_id,
  add column wash_group_id uuid not null,
  add foreign key (wash_group_id, plant_id) references public.wash_groups(id, plant_id);
create index soil_estimates_current_idx on public.soil_estimates (plant_id, wash_group_id, entered_at desc);
create index soil_estimates_group_plant_idx on public.soil_estimates (wash_group_id, plant_id);

create or replace function app.check_estimate_unit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- Security M2: no cross-tenant oracle; RLS rejects rows on plants the caller has no role on.
  if (select auth.uid()) is not null and not app.has_role(new.plant_id, '{owner,manager,lead,viewer}') then
    return new;
  end if;
  -- Security H1: look the group up in the row's own plant only. Not found (another plant's or a
  -- missing group) → the composite FK reports it, whatever that foreign group allows.
  if new.unit = 'basket' and exists (
       select 1 from public.wash_groups g
        where g.id = new.wash_group_id and g.plant_id = new.plant_id and not g.allow_basket_estimates) then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: basket estimates are not allowed for this wash group';
  end if;
  return new;
end;
$$;
comment on function app.check_estimate_unit() is
  '§4.5 BEFORE INSERT on soil_estimates: rejects unit basket when the row''s wash group (looked up in the row''s plant only, H1) does not allow basket estimates (VALIDATION_FAILED); a foreign or missing group is left to the FK (23503).';

-- ── 5. queue_items: per wash group; optional item (must be in the group) ──
alter table public.queue_items
  add column wash_group_id uuid not null,
  alter column item_type_id drop not null,
  add foreign key (wash_group_id, plant_id) references public.wash_groups(id, plant_id),
  add constraint queue_items_piece_pack_need_item check (unit in ('load','basket') or item_type_id is not null);
create index queue_items_group_plant_idx on public.queue_items (wash_group_id, plant_id);
comment on column public.queue_items.wash_group_id is
  'Owner 2026-11-01: the wash group this work is for (what the washroom TVs show).';
comment on column public.queue_items.item_type_id is
  'Optional item inside wash_group_id (checked by app.check_queue_item_group). Required for piece/pack quantities (finishing work).';

create function app.check_queue_item_group()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_group uuid;
begin
  -- Security M2: no cross-tenant oracle; RLS rejects rows on plants the caller has no role on.
  if (select auth.uid()) is not null and not app.has_role(new.plant_id, '{owner,manager,lead,viewer}') then
    return new;
  end if;
  if new.item_type_id is null then
    return new;
  end if;
  -- Security H1: the item is looked up in the row's own plant only. Not found → the FK reports it.
  select i.wash_group_id into v_group
    from public.item_types i
   where i.id = new.item_type_id and i.plant_id = new.plant_id;
  if not found then
    return new;
  end if;
  if new.wash_group_id is null then
    new.wash_group_id := v_group;      -- convenience: the item's group (architect N4)
  elsif new.wash_group_id <> v_group then
    raise exception 'VALIDATION_FAILED' using detail = 'item_type_id: the item is not in this wash group';
  end if;
  return new;
end;
$$;
comment on function app.check_queue_item_group() is
  'BEFORE INSERT / UPDATE OF item_type_id, wash_group_id on queue_items: fills a null wash_group_id from the item; otherwise an item, when given, must belong to the row''s wash group (VALIDATION_FAILED). Items are looked up in the row''s plant only (H1); a foreign or missing item is left to the FK. A trigger, not a FK, so moving an item to another group later never fails on old queue rows.';
create trigger queue_items_check_group before insert or update of item_type_id, wash_group_id on public.queue_items
  for each row execute function app.check_queue_item_group();

-- ── 5b. finished_goods_entries: snapshot the item's wash group (architect N1) ──
alter table public.finished_goods_entries
  add column wash_group_id uuid not null,
  add foreign key (wash_group_id, plant_id) references public.wash_groups(id, plant_id);
create index fge_group_plant_idx on public.finished_goods_entries (wash_group_id, plant_id);
comment on column public.finished_goods_entries.wash_group_id is
  'Snapshot of the item''s wash group at insert (set by app.set_entry_wash_group; any client value is ignored). Reconciliation groups by it, so moving the item later never rewrites history.';

create function app.set_entry_wash_group()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- Security H1: the item is looked up in the row's own plant only; any client value is overwritten.
  select i.wash_group_id into new.wash_group_id
    from public.item_types i
   where i.id = new.item_type_id and i.plant_id = new.plant_id;
  if not found then
    -- Security M2: a caller with no role on the plant gets RLS's 42501 (it runs before NOT NULL).
    if (select auth.uid()) is not null and not app.has_role(new.plant_id, '{owner,manager,lead,viewer}') then
      return new;
    end if;
    -- Same answer as the item FK for any foreign or missing item (NOT NULL would fire before the FK).
    raise exception using errcode = 'foreign_key_violation',
      message = 'item_type_id: item not found in this plant';
  end if;
  return new;
end;
$$;
comment on function app.set_entry_wash_group() is
  'BEFORE INSERT on finished_goods_entries: wash_group_id := the item''s current wash group (client value ignored). The item is looked up in the row''s plant only (H1); not found raises 23503, like the item FK.';
create trigger fge_set_wash_group before insert on public.finished_goods_entries
  for each row execute function app.set_entry_wash_group();

-- Security H1: apply_count_mode (20261101115542) looked the item up by id alone, so a caller on their
-- own plant could tell a foreign item's count mode (COUNT_MODE_MISMATCH vs 23503). Same body, plus
-- the plant filter; not found → the FK reports it.
create or replace function app.apply_count_mode()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_mode app.count_mode;
  v_size int;
begin
  -- Security M2: no cross-tenant oracle; RLS rejects rows on plants the caller has no role on.
  if (select auth.uid()) is not null and not app.has_role(new.plant_id, '{owner,manager,lead,viewer}') then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and (new.packs, new.pack_size_used, new.loose_pieces)
         is not distinct from (old.packs, old.pack_size_used, old.loose_pieces) then
    return new;
  end if;
  select i.count_mode, i.pack_size into v_mode, v_size
    from public.item_types i where i.id = new.item_type_id and i.plant_id = new.plant_id;
  if not found then
    return new;  -- the item FK reports it
  end if;
  if v_mode = 'unit' then
    if new.packs <> 0 or new.pack_size_used is not null then
      raise exception 'COUNT_MODE_MISMATCH' using detail = 'unit-counted item: packs must be 0 and pack_size_used null';
    end if;
  elsif new.pack_size_used is null and new.packs > 0 then
    if v_size is null then
      raise exception 'CONVERSION_MISSING' using detail = 'pack item has no pack_size';
    end if;
    new.pack_size_used := v_size;   -- past entries keep the size they were recorded with
  end if;
  return new;
end;
$$;
comment on function app.apply_count_mode() is
  '§4.5 BEFORE INSERT / UPDATE OF packs, pack_size_used, loose_pieces on finished_goods_entries: unit items need packs=0 and no pack size (COUNT_MODE_MISMATCH); pack items copy the item''s pack_size when packs>0 and none was given. The item is looked up in the row''s plant only (H1); not found is left to the FK.';

-- ── 6. washer_cycles: per wash group (F1/F3) ──────────────────────────────
-- The trigger's column list names item_type_id, so it goes before the column.
drop trigger washer_cycles_resolve_item on public.washer_cycles;
drop function app.resolve_item_from_formula();
alter table public.washer_cycles
  drop column item_type_id,
  add column wash_group_id uuid,                                    -- resolved from formula or chosen manually
  add foreign key (wash_group_id, plant_id) references public.wash_groups(id, plant_id),
  add constraint washer_cycles_group_or_formula check (wash_group_id is not null or wash_formula_id is not null);
create index washer_cycles_shift_group_idx on public.washer_cycles (shift_instance_id, wash_group_id);
create index washer_cycles_group_started_idx on public.washer_cycles (wash_group_id, started_at);
create index washer_cycles_group_plant_idx on public.washer_cycles (wash_group_id, plant_id);

create function app.resolve_group_from_formula()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.wash_group_id is null and new.wash_formula_id is not null then
    select f.wash_group_id into new.wash_group_id
      from public.wash_formulas f
     where f.id = new.wash_formula_id and f.plant_id = new.plant_id;
  end if;
  return new;
end;
$$;
comment on function app.resolve_group_from_formula() is
  '§4.5 BEFORE INSERT/UPDATE on washer_cycles: copies the wash formula''s wash_group_id when wash_group_id is null (still null = unmapped formula).';
create trigger washer_cycles_resolve_group before insert or update of wash_group_id, wash_formula_id
  on public.washer_cycles for each row execute function app.resolve_group_from_formula();

-- Snapshot of the machine's load_factor (architect N1): editing a machine never moves past standard_loads.
alter table public.washer_cycles
  add column load_factor_used numeric(4,2) not null
    constraint washer_cycles_load_factor_used_range check (load_factor_used between 0.25 and 4.00);
comment on column public.washer_cycles.load_factor_used is
  'Snapshot of machines.load_factor at insert (1.00 without a machine), set by app.set_cycle_load_factor; any client value is ignored. standard_loads = load_count × load_factor_used.';

create function app.set_cycle_load_factor()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.machine_id is null then
    new.load_factor_used := 1.00;
    return new;
  end if;
  -- Security H1: the machine is looked up in the row's own plant only; any client value is overwritten.
  select m.load_factor into new.load_factor_used
    from public.machines m
   where m.id = new.machine_id and m.plant_id = new.plant_id;
  if not found then
    -- Security M2: a caller with no role on the plant gets RLS's 42501 (it runs before NOT NULL).
    if (select auth.uid()) is not null and not app.has_role(new.plant_id, '{owner,manager,lead,viewer}') then
      return new;
    end if;
    raise exception using errcode = 'foreign_key_violation',
      message = 'machine_id: machine not found in this plant';   -- same answer as the machine FK
  end if;
  return new;
end;
$$;
comment on function app.set_cycle_load_factor() is
  'BEFORE INSERT on washer_cycles: load_factor_used := the machine''s current load_factor (1.00 without a machine; client value ignored). The machine is looked up in the row''s plant only (H1); not found raises 23503, like the machine FK.';
create trigger washer_cycles_set_load_factor before insert on public.washer_cycles
  for each row execute function app.set_cycle_load_factor();

-- ── 7. Languages: wash_groups.name_i18n follows the item_types rules ──────
create or replace function app.check_languages()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_enabled text[];
  v_code    text;
  v_val     jsonb;
  v_max     int := 60;
  v_map     jsonb;
begin
  if tg_table_name = 'plants' then
    if exists (select 1 from unnest(new.enabled_languages) c
                where not exists (select 1 from public.languages l where l.code = c)) then
      raise exception 'VALIDATION_FAILED' using detail = 'enabled_languages: unknown language code';
    end if;
    if not (new.default_language = any (new.enabled_languages)) then
      raise exception 'VALIDATION_FAILED' using detail = 'default_language: must be in enabled_languages';
    end if;
    return new;
  end if;

  if tg_table_name = 'profiles' then
    -- A user's language must be enabled in at least one plant they belong to (if any yet).
    select coalesce(array_agg(distinct l), '{}') into v_enabled
      from public.memberships m
      join public.plants p on p.org_id = m.org_id and (m.plant_id is null or m.plant_id = p.id)
      cross join lateral unnest(p.enabled_languages) l
     where m.user_id = new.user_id and m.revoked_at is null;
    if cardinality(v_enabled) > 0 and not (new.language = any (v_enabled)) then
      raise exception 'VALIDATION_FAILED' using detail = 'language: not enabled for any of the user''s plants';
    end if;
    return new;
  end if;

  -- Plant-scoped tables: devices, item_types, wash_groups, display_messages, entry_staff.
  -- Security M2: never validate (and so never leak) another tenant's plant settings. A client
  -- without a role on the row's plant passes through and RLS rejects the row (42501). Service
  -- role / postgres (auth.uid() null) are always validated.
  if (select auth.uid()) is not null and not app.has_role(new.plant_id, '{owner,manager,lead,viewer}') then
    return new;
  end if;
  select p.enabled_languages into v_enabled from public.plants p where p.id = new.plant_id;
  if v_enabled is null then
    return new;  -- the plant FK reports the missing plant
  end if;

  if tg_table_name = 'devices' then
    if exists (select 1 from unnest(new.display_languages) c where not (c = any (v_enabled))) then
      raise exception 'VALIDATION_FAILED' using detail = 'display_languages: not enabled for the plant';
    end if;
    return new;
  elsif tg_table_name = 'entry_staff' then
    if not (new.language = any (v_enabled)) then
      raise exception 'VALIDATION_FAILED' using detail = 'language: not enabled for the plant';
    end if;
    return new;
  elsif tg_table_name in ('item_types', 'wash_groups') then
    v_map := new.name_i18n;
  elsif tg_table_name = 'display_messages' then
    if not (new.body_lang = any (v_enabled)) then
      raise exception 'VALIDATION_FAILED' using detail = 'body_lang: not enabled for the plant';
    end if;
    v_map := new.body_i18n;
    v_max := 140;
  else
    raise exception 'app.check_languages() is not configured for table %', tg_table_name;
  end if;

  for v_code, v_val in select key, value from jsonb_each(v_map) loop
    if not (v_code = any (v_enabled)) then
      raise exception 'VALIDATION_FAILED' using detail = format('i18n: language %s not enabled for the plant', v_code);
    end if;
    if jsonb_typeof(v_val) <> 'string'
       or char_length(v_val #>> '{}') not between 1 and v_max
       or not app.is_clean_text(v_val #>> '{}') then
      raise exception 'VALIDATION_FAILED' using detail = format('i18n: value for %s must be 1–%s clean characters', v_code, v_max);
    end if;
  end loop;
  return new;
end;
$$;
comment on function app.check_languages() is
  '§4.5 BEFORE INSERT/UPDATE on plants, profiles, devices, item_types, wash_groups, display_messages, entry_staff: language codes exist and are enabled for the plant; i18n values 1–60 (140 for messages) chars.';

-- ── 8. §4.6 conversion: still the single source of truth ──────────────────
-- SECURITY INVOKER: the caller's RLS on wash_groups/item_types applies (no cross-tenant factors).
-- p_wash_group_id may be null when p_item_type_id is given (the item's group is used). An item that
-- is not in the given group, or a missing/invisible group or item, gives null.
create function app.to_loads(p_wash_group_id uuid, p_item_type_id uuid, p_qty numeric, p_unit app.qty_unit)
returns numeric language sql stable set search_path = '' as $$
  select case p_unit
           when 'load'   then p_qty
           when 'basket' then p_qty / g.baskets_per_load
           when 'piece'  then p_qty / i.pieces_per_load
           when 'pack'   then p_qty * i.pack_size / i.pieces_per_load
         end
    from public.wash_groups g
    left join public.item_types i on i.id = p_item_type_id and i.wash_group_id = g.id
   where g.id = coalesce(p_wash_group_id,
                         (select it.wash_group_id from public.item_types it where it.id = p_item_type_id))
     and (p_item_type_id is null or i.id is not null);
$$;
comment on function app.to_loads(uuid, uuid, numeric, app.qty_unit) is
  '§4.6 Converts qty in unit to standard wash loads. load = qty; basket = qty / wash group baskets_per_load; piece = qty / item pieces_per_load; pack = qty × item pack_size / item pieces_per_load. Null when a factor, the group or the item is missing (or the item is not in the group). piece/pack are approximate.';
revoke all on function app.to_loads(uuid, uuid, numeric, app.qty_unit) from public, anon;
grant execute on function app.to_loads(uuid, uuid, numeric, app.qty_unit) to authenticated, service_role;

-- ── 9. Reporting views (security_invoker; same grants as before) ──────────
create view public.current_soil_estimates with (security_invoker = true) as
select distinct on (e.plant_id, e.wash_group_id)
       e.org_id,
       e.plant_id,
       e.wash_group_id,
       g.name                                          as wash_group_name,
       g.name_i18n                                     as wash_group_name_i18n,
       e.id                                            as estimate_id,
       e.qty,
       e.unit,
       app.to_loads(e.wash_group_id, null, e.qty, e.unit) as qty_loads,
       app.to_loads(e.wash_group_id, null, e.qty, e.unit) is not null as has_conversion,
       e.entered_at,
       e.entered_by,
       e.staff_id,
       st.display_name                                 as entered_by_name,   -- null unless caller may read entry staff
       floor(extract(epoch from (now() - e.entered_at)) / 60)::int as age_minutes,
       case
         when now() - e.entered_at >= make_interval(mins => p.estimate_red_minutes)   then 'red'
         when now() - e.entered_at >= make_interval(mins => p.estimate_amber_minutes) then 'amber'
         else 'ok'
       end                                             as freshness
  from public.soil_estimates e
  join public.plants p on p.id = e.plant_id
  join public.wash_groups g on g.id = e.wash_group_id
  left join public.entry_staff st on st.id = e.staff_id
 order by e.plant_id, e.wash_group_id, e.entered_at desc, e.id desc;
comment on view public.current_soil_estimates is
  '§4.6 Latest soil estimate per wash group with load equivalent (basket via the group''s baskets_per_load; null = no conversion), age and freshness (ok/amber/red per plant thresholds).';

create view public.queue_board with (security_invoker = true) as
select q.org_id,
       q.plant_id,
       q.area_id,
       q.id,
       q.position,
       q.is_rush,
       q.status,
       q.qty,
       q.unit,
       app.to_loads(q.wash_group_id, q.item_type_id, q.qty, q.unit) as qty_loads,
       q.unit in ('piece', 'pack')                     as approximate,
       q.wash_group_id,
       g.name                                          as wash_group_name,
       g.name_i18n                                     as wash_group_name_i18n,
       g.color_hex                                     as wash_group_color_hex,
       q.item_type_id,                                 -- null for group-level (washroom) work
       i.name                                          as item_name,
       i.name_i18n                                     as item_name_i18n,
       i.color_hex                                     as item_color_hex,
       q.note,
       q.version,
       q.started_at,
       q.created_at
  from public.queue_items q
  join public.wash_groups g on g.id = q.wash_group_id
  left join public.item_types i on i.id = q.item_type_id
 where q.status in ('queued', 'in_progress');
comment on view public.queue_board is
  '§4.6 Open queue (queued/in_progress) per area: wash group names in all languages, plus the optional item; qty_loads via app.to_loads (piece/pack approximate, null without a factor). Order by is_rush desc, position asc.';

create view public.washroom_by_shift with (security_invoker = true) as
select w.org_id,
       w.plant_id,
       w.area_id,
       w.shift_instance_id,
       coalesce(si.production_date, app.production_date(w.started_at, p.timezone, p.production_day_start)) as production_date,
       w.wash_group_id,
       sum(w.load_count)::int                                     as loads_run,
       sum(w.load_count * w.load_factor_used)::numeric             as standard_loads,
       coalesce(bool_or(w.load_factor_used <> 1), false)           as approximate
  from public.washer_cycles w
  join public.plants p on p.id = w.plant_id
  left join public.shift_instances si on si.id = w.shift_instance_id
 group by w.org_id, w.plant_id, w.area_id, w.shift_instance_id, 5, w.wash_group_id;
comment on view public.washroom_by_shift is
  '§4.6 Washroom per wash group per shift instance (wash_group_id null = unmapped formula): loads_run = sum(load_count); standard_loads = sum(load_count × load_factor_used) (the machine''s factor snapshotted at insert, 1 without machine); approximate = some load had a factor ≠ 1. production_date = production day (instance, or app.production_date(started_at) off-shift).';

create view public.finished_by_shift with (security_invoker = true) as
select f.org_id,
       f.plant_id,
       f.area_id,
       f.shift_instance_id,
       coalesce(si.production_date, app.production_date(f.occurred_at, p.timezone, p.production_day_start)) as production_date,
       f.item_type_id,
       f.wash_group_id,
       f.station_id,
       sum(f.packs)::int                               as packs,
       sum(f.loose_pieces)::int                        as loose_pieces,
       sum(f.pieces)::int                              as pieces,
       app.to_loads(null, f.item_type_id, sum(f.pieces)::numeric, 'piece') as loads_approx,
       true                                            as approximate,
       app.to_loads(null, f.item_type_id, sum(f.pieces)::numeric, 'piece') is not null as has_conversion
  from public.finished_goods_entries f
  join public.plants p on p.id = f.plant_id
  left join public.shift_instances si on si.id = f.shift_instance_id
 where f.voided_at is null
 group by f.org_id, f.plant_id, f.area_id, f.shift_instance_id, 5, f.item_type_id, f.wash_group_id, f.station_id;
comment on view public.finished_by_shift is
  '§4.6 Non-voided finished goods per ITEM and line per shift instance (wash_group_id = the item''s group when entered, snapshotted); loads_approx = to_loads(pieces, ''piece'') (approximate, null without pieces_per_load). production_date = production day (instance, or app.production_date(occurred_at) off-shift).';

-- Reconciliation per (production_date, wash_group). Finished loads ≈ Σ over the group's items of
-- to_loads(pieces, 'piece'). If any finished item of the group has no pieces_per_load, the total is
-- NOT silently undercounted: loads_finished_approx and clean_backlog_loads_approx are null,
-- finished_incomplete is true, pieces_without_conversion counts the unconverted pieces, and
-- loads_finished_partial_approx carries the sum over the items that do convert (a lower bound).
create view public.daily_reconciliation with (security_invoker = true) as
with washed as (
  select w.org_id, w.plant_id,
         coalesce(si.production_date, app.production_date(w.started_at, p.timezone, p.production_day_start)) as production_date,
         w.wash_group_id,
         sum(w.load_count)::numeric                              as loads_run,
         sum(w.load_count * w.load_factor_used)::numeric          as standard_loads
    from public.washer_cycles w
    join public.plants p on p.id = w.plant_id
    left join public.shift_instances si on si.id = w.shift_instance_id
   where w.wash_group_id is not null
   group by 1, 2, 3, 4
), finished_items as (
  select f.org_id, f.plant_id,
         coalesce(si.production_date, app.production_date(f.occurred_at, p.timezone, p.production_day_start)) as production_date,
         f.wash_group_id,
         f.item_type_id,
         sum(f.pieces)::numeric as pieces
    from public.finished_goods_entries f
    join public.plants p on p.id = f.plant_id
    left join public.shift_instances si on si.id = f.shift_instance_id
   where f.voided_at is null
   group by 1, 2, 3, 4, 5
), finished as (
  select fi.org_id, fi.plant_id, fi.production_date, fi.wash_group_id,
         sum(fi.pieces)                                                   as pieces_finished,
         count(*)::int                                                    as items_finished,
         coalesce(sum(fi.pieces) filter (where c.loads is null), 0)::int  as pieces_without_conversion,
         coalesce(sum(c.loads), 0)                                        as loads_converted
    from finished_items fi
    cross join lateral (select app.to_loads(null, fi.item_type_id, fi.pieces, 'piece') as loads) c
   group by 1, 2, 3, 4
), keyed as (
  select coalesce(w.org_id, f.org_id)                   as org_id,
         coalesce(w.plant_id, f.plant_id)               as plant_id,
         coalesce(w.production_date, f.production_date) as production_date,
         coalesce(w.wash_group_id, f.wash_group_id)     as wash_group_id,
         coalesce(w.loads_run, 0)                       as loads_run,
         coalesce(w.standard_loads, 0)                  as standard_loads,
         coalesce(f.pieces_finished, 0)                 as pieces_finished,
         coalesce(f.items_finished, 0)                  as items_finished,
         coalesce(f.pieces_without_conversion, 0)       as pieces_without_conversion,
         coalesce(f.loads_converted, 0)                 as loads_converted
    from washed w
    full join finished f
      on f.plant_id = w.plant_id and f.production_date = w.production_date and f.wash_group_id = w.wash_group_id
)
select k.org_id,
       k.plant_id,
       k.production_date,
       k.wash_group_id,
       g.name                                                  as wash_group_name,
       g.name_i18n                                             as wash_group_name_i18n,
       est_start.qty_loads                                     as est_loads_start,
       k.loads_run,
       k.standard_loads,
       k.pieces_finished,
       k.items_finished,
       k.pieces_without_conversion,
       k.pieces_without_conversion > 0                         as finished_incomplete,
       k.loads_converted                                       as loads_finished_partial_approx,
       case when k.pieces_without_conversion = 0 then k.loads_converted end                     as loads_finished_approx,
       case when k.pieces_without_conversion = 0 then k.standard_loads - k.loads_converted end  as clean_backlog_loads_approx,
       est_end.qty_loads                                       as est_loads_end,
       null::numeric                                           as estimate_error_pct,
       true                                                    as approximate
  from keyed k
  join public.plants p on p.id = k.plant_id
  join public.wash_groups g on g.id = k.wash_group_id
  cross join lateral (
    select coalesce(min(si.starts_at), (k.production_date + p.production_day_start) at time zone p.timezone)     as day_start,
           coalesce(max(si.ends_at), ((k.production_date + 1) + p.production_day_start) at time zone p.timezone) as day_end
      from public.shift_instances si
     where si.plant_id = k.plant_id and si.production_date = k.production_date and si.skipped_at is null
  ) b
  left join lateral (
    select app.to_loads(e.wash_group_id, null, e.qty, e.unit) as qty_loads
      from public.soil_estimates e
     where e.plant_id = k.plant_id and e.wash_group_id = k.wash_group_id and e.entered_at <= b.day_start
     order by e.entered_at desc, e.id desc
     limit 1
  ) est_start on true
  left join lateral (
    select app.to_loads(e.wash_group_id, null, e.qty, e.unit) as qty_loads
      from public.soil_estimates e
     where e.plant_id = k.plant_id and e.wash_group_id = k.wash_group_id and e.entered_at <= b.day_end
     order by e.entered_at desc, e.id desc
     limit 1
  ) est_end on true;
comment on view public.daily_reconciliation is
  '§4.6/G1 Washroom vs finishing per WASH GROUP per PRODUCTION DAY (owner 2026-11-01). loads_run = sum(load_count); standard_loads = sum(load_count × load_factor_used). loads_finished_approx = Σ over the group''s items of to_loads(pieces, ''piece''); it and clean_backlog_loads_approx (= standard_loads − loads_finished_approx) are null when finished_incomplete (some finished pieces have no pieces_per_load: see pieces_without_conversion; loads_finished_partial_approx = sum over the items that convert). Finished goods count in the wash group snapshotted on each entry and washer loads at the load factor snapshotted on each cycle, so later catalog/machine edits never rewrite history. approximate is always true. estimate_error_pct stays null until the owner approves its formula.';

revoke all on public.current_soil_estimates, public.queue_board, public.washroom_by_shift,
              public.finished_by_shift, public.daily_reconciliation from anon, authenticated;
grant select on public.current_soil_estimates, public.queue_board, public.washroom_by_shift,
               public.finished_by_shift, public.daily_reconciliation to authenticated;

-- Security L2: no client TRUNCATE on the new table either.
revoke truncate on public.wash_groups from anon, authenticated;
