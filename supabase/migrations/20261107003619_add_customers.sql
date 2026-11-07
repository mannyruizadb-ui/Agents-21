-- Outside customers (owner 2026-11-06, A): customers are DATA, not hard-coded. First one: AA Linen.
--
-- * public.customers: per plant, name + name_i18n, active, sort_order. Owners and managers read; owners
--   write (RLS + column grants, like routes). Deactivate, never delete.
-- * "Everything of theirs is separate": a customer's goods are their own wash groups.
--   wash_groups.customer_id (null = our own goods). The owner adds / removes customer products in the
--   app: insert / update of customer_id is granted, and a trigger lets only OWNERS set or change it
--   (managers keep their existing wash_groups edit rights for everything else).
--   Name uniqueness is now per (plant, customer, name), so AA "Kitchen towels" can sit next to ours.
-- * queue_items.customer_id and washer_cycles.customer_id: snapshots of the wash group's customer,
--   always set by BEFORE INSERT triggers (any client value is overwritten), never changed afterwards.
--   start_washer_load (and every other insert path) gets it without a signature change, so the owner can
--   later report washing time spent on AA Linen. Existing rows stay null (= our goods; no AA groups
--   existed before this migration, so nothing to backfill).
-- * DATA (idempotent; seed.sql carries the same for fresh databases): customer "AA Linen" and its 8 wash
--   groups for the ADB plant. Loads per bin null (the owner fills them in) except Mats = 4 per bin.
--   Colors: 8 new distinct presets, each ≥ 3:1 against the white and the dark (TV) card, so AA chips
--   never look like ours. wash_formula_id is nullable and left null: the owner picks each formula in the app (until then the
--   running guard and the washer idle alarm cannot time AA loads).

-- ── customers ─────────────────────────────────────────────────────────────
create table public.customers (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  plant_id    uuid not null,
  name        text not null check (char_length(name) between 1 and 60 and app.is_clean_text(name)),
  name_i18n   jsonb not null default '{}'::jsonb check (jsonb_typeof(name_i18n) = 'object'),
  active      boolean not null default true,
  sort_order  int not null default 0 check (sort_order between -100000 and 100000),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  unique (plant_id, name),
  unique (id, plant_id)
);
alter table public.customers enable row level security;
create index customers_plant_org_idx on public.customers (plant_id, org_id);
comment on table public.customers is
  'Owner 2026-11-06 (A): outside customers whose goods ADB washes separately (first: AA Linen). Their goods are their own wash groups (wash_groups.customer_id). Owners/managers read; owners write (column grants). Deactivate, never delete.';
create trigger customers_touch_updated_at before update on public.customers for each row execute function app.touch_updated_at();
create trigger customers_audit after insert or update on public.customers for each row execute function app.audit();
create trigger customers_check_languages before insert or update of name_i18n, plant_id on public.customers
  for each row execute function app.check_languages();
create trigger customers_prevent_delete before delete on public.customers for each row execute function app.prevent_delete();
create trigger customers_prevent_truncate before truncate on public.customers for each statement execute function app.prevent_delete();
create policy customers_select on public.customers for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')));
create policy customers_insert on public.customers for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner}')));
create policy customers_update on public.customers for update to authenticated
  using ((select app.has_role(plant_id, '{owner}'))) with check ((select app.has_role(plant_id, '{owner}')));
revoke all on public.customers from anon, authenticated;
grant select on public.customers to authenticated;
grant insert (org_id, plant_id, name, name_i18n, sort_order, active) on public.customers to authenticated;
grant update (name, name_i18n, sort_order, active) on public.customers to authenticated;

-- app.check_languages: + customers (name_i18n, 60 characters).
CREATE OR REPLACE FUNCTION app.check_languages()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  -- Plant-scoped tables: devices, item_types, wash_groups, customers, display_messages, entry_staff.
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
  elsif tg_table_name in ('item_types', 'wash_groups', 'customers') then
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
$function$

;

-- ── wash_groups.customer_id ───────────────────────────────────────────────
alter table public.wash_groups
  add column customer_id uuid,
  add constraint wash_groups_customer_fkey foreign key (customer_id, plant_id) references public.customers(id, plant_id),
  drop constraint wash_groups_plant_id_name_key,
  add constraint wash_groups_plant_customer_name_key unique nulls not distinct (plant_id, customer_id, name);
create index wash_groups_customer_plant_idx on public.wash_groups (customer_id, plant_id);
comment on column public.wash_groups.customer_id is
  'Owner 2026-11-06 (A): the outside customer whose goods this group is (null = our own goods). Set or changed by OWNERS only (trigger). Snapshotted onto queue_items / washer_cycles at insert.';
grant insert (customer_id), update (customer_id) on public.wash_groups to authenticated;

create function app.guard_wash_group_customer()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    return new;                                  -- service role / migrations
  end if;
  if not app.has_role(new.plant_id, '{owner,manager,lead,viewer}') then
    return new;                                  -- RLS rejects it; no oracle
  end if;
  if (tg_op = 'INSERT' and new.customer_id is not null)
     or (tg_op = 'UPDATE' and new.customer_id is distinct from old.customer_id) then
    if not app.has_role(new.plant_id, '{owner}') then
      raise exception 'NOT_AUTHORIZED' using detail = 'customer_id: owner only';
    end if;
  end if;
  return new;
end;
$$;
comment on function app.guard_wash_group_customer() is
  'Owner 2026-11-06 (A): only owners may set or change wash_groups.customer_id (managers keep their other wash group edits). Trigger.';
revoke all on function app.guard_wash_group_customer() from public, anon, authenticated;
create trigger wash_groups_guard_customer before insert or update of customer_id on public.wash_groups
  for each row execute function app.guard_wash_group_customer();

-- ── Snapshots on queue_items and washer_cycles ────────────────────────────
alter table public.queue_items
  add column customer_id uuid,
  add constraint queue_items_customer_fkey foreign key (customer_id, plant_id) references public.customers(id, plant_id);
create index queue_items_customer_plant_idx on public.queue_items (customer_id, plant_id);
comment on column public.queue_items.customer_id is
  'Owner 2026-11-06 (A): the wash group''s customer when the item was created (null = our goods). Set by trigger; never changed.';
grant select (customer_id) on public.queue_items to authenticated;

alter table public.washer_cycles
  add column customer_id uuid,
  add constraint washer_cycles_customer_fkey foreign key (customer_id, plant_id) references public.customers(id, plant_id);
create index washer_cycles_customer_plant_idx on public.washer_cycles (customer_id, plant_id);
comment on column public.washer_cycles.customer_id is
  'Owner 2026-11-06 (A): the wash group''s customer when the load started (snapshot; null = our goods or no group). Set by trigger; never changed. For "washing time spent on AA Linen".';
grant select (customer_id) on public.washer_cycles to authenticated;

create function app.set_row_customer()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.customer_id := old.customer_id;          -- a snapshot never changes
    return new;
  end if;
  -- Looked up in the row's own plant only; any client value is overwritten.
  select g.customer_id into new.customer_id
    from public.wash_groups g where g.id = new.wash_group_id and g.plant_id = new.plant_id;
  if not found then
    new.customer_id := null;
  end if;
  return new;
end;
$$;
comment on function app.set_row_customer() is
  'Owner 2026-11-06 (A): BEFORE INSERT / UPDATE trigger on queue_items and washer_cycles: customer_id := the wash group''s customer at insert (same plant; null when no group), and never changes afterwards.';
revoke all on function app.set_row_customer() from public, anon, authenticated;
-- washer_cycles: fires after washer_cycles_resolve_group (alphabetical), so a formula-only import gets
-- its group first.
create trigger queue_items_set_customer before insert or update of customer_id on public.queue_items
  for each row execute function app.set_row_customer();
create trigger washer_cycles_set_customer before insert or update of customer_id on public.washer_cycles
  for each row execute function app.set_row_customer();

-- ── DATA: AA Linen and its wash groups (ADB plant; idempotent) ────────────
insert into public.customers (org_id, plant_id, name, name_i18n, sort_order)
select p.org_id, p.id, 'AA Linen', '{}'::jsonb, 10
  from public.plants p
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 where p.name = 'Miami'
on conflict (plant_id, name) do nothing;

insert into public.wash_groups (org_id, plant_id, customer_id, name, name_i18n, color_hex, sort_order,
                                loads_per_bin, allow_bin_estimates)
select c.org_id, c.plant_id, c.id, v.name, pg_catalog.jsonb_build_object('es', v.es), v.color, v.sort_order,
       v.per_bin, v.per_bin is not null
  from public.customers c
  join public.plants p on p.id = c.plant_id and p.name = 'Miami'
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
   ('Kitchen towels',            'Toallas de cocina',             '#C2410C', 1000, null::numeric),
   ('Aprons',                    'Delantales',                    '#0E7490', 1010, null),
   ('Mats',                      'Mapos',                         '#A16207', 1020, 4),
   ('Napkins',                   'Servilletas',                   '#15803D', 1030, null),
   ('Tablecloths',               'Manteles',                      '#E11D48', 1040, null),
   ('Stained white napkins',     'Servilletas blancas manchadas', '#9333EA', 1050, null),
   ('Stained white tablecloths', 'Manteles blancos manchados',    '#0284C7', 1060, null),
   ('Stained hotel towels',      'Toallas de hotel manchadas',    '#059669', 1070, null)) as v(name, es, color, sort_order, per_bin)
 where c.name = 'AA Linen'
   and not exists (select 1 from public.wash_groups g
                    where g.plant_id = c.plant_id and g.customer_id = c.id and g.name = v.name);
