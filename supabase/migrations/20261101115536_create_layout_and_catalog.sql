-- M1 · plant layout + item catalog (PRD A2, A3; §4.4 areas…wash_formulas; §4.6 app.to_loads).
-- §4.7: areas, stations, machines, item_types, wash_formulas → owner/manager R C U; lead, viewer,
-- display (own plant, D13) R.

create table public.areas (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  plant_id    uuid not null,
  name        text not null check (char_length(name) between 1 and 60 and app.is_clean_text(name)),
  kind        app.area_kind not null,
  sort_order  int not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  unique (id, plant_id),
  unique (plant_id, name)
);
alter table public.areas enable row level security;
create index areas_plant_org_idx on public.areas (plant_id, org_id);

create table public.stations (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  plant_id    uuid not null,
  area_id     uuid not null,
  name        text not null check (char_length(name) between 1 and 60 and app.is_clean_text(name)),
  kind        app.station_kind not null,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (area_id, plant_id) references public.areas(id, plant_id),
  unique (id, plant_id),
  unique (plant_id, name)
);
alter table public.stations enable row level security;
create index stations_plant_org_idx on public.stations (plant_id, org_id);
create index stations_area_plant_idx on public.stations (area_id, plant_id);

create table public.machines (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null,
  plant_id     uuid not null,
  area_id      uuid not null,
  name         text not null check (char_length(name) between 1 and 60 and app.is_clean_text(name)),
  kind         app.machine_kind not null,
  vendor       text check (char_length(vendor) <= 60 and app.is_clean_text(vendor)),
  model        text check (char_length(model) <= 60 and app.is_clean_text(model)),
  external_ref text check (char_length(external_ref) <= 80 and app.is_clean_text(external_ref)),
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (area_id, plant_id) references public.areas(id, plant_id),
  unique (id, plant_id),
  unique (plant_id, external_ref)
);
alter table public.machines enable row level security;
create index machines_plant_org_idx on public.machines (plant_id, org_id);
create index machines_area_plant_idx on public.machines (area_id, plant_id);

create table public.item_types (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null,
  plant_id         uuid not null,
  name             text not null check (char_length(name) between 1 and 60 and app.is_clean_text(name)),
  name_i18n        jsonb not null default '{}'::jsonb check (jsonb_typeof(name_i18n) = 'object'),
  category         app.item_category not null,
  default_estimate_unit  app.qty_unit not null default 'load'
                   check (default_estimate_unit in ('load','basket')),
  allow_basket_estimates boolean not null default false,
  baskets_per_load numeric(8,3) check (baskets_per_load > 0),
  count_mode       app.count_mode not null default 'unit',
  pack_size        int check (pack_size between 1 and 10000),
  pieces_per_load  numeric(10,2) check (pieces_per_load > 0),
  pieces_per_load_source text check (pieces_per_load_source in ('counted','derived')),
  color_hex        text not null default '#64748B' check (color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  sort_order       int not null default 0,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  unique (id, plant_id),
  unique (plant_id, name),
  check (count_mode <> 'pack' or pack_size is not null),
  check (not allow_basket_estimates or baskets_per_load is not null),
  check (default_estimate_unit <> 'basket' or allow_basket_estimates),
  check ((pieces_per_load is null) = (pieces_per_load_source is null))
);
alter table public.item_types enable row level security;
create index item_types_plant_org_idx on public.item_types (plant_id, org_id);

create table public.wash_formulas (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null,
  plant_id       uuid not null,
  external_no    text not null check (char_length(external_no) between 1 and 20 and app.is_clean_text(external_no)),
  name           text check (char_length(name) <= 80 and app.is_clean_text(name)),
  item_type_id   uuid,                                    -- null = unmapped / mixed
  created_at     timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (item_type_id, plant_id) references public.item_types(id, plant_id),
  unique (id, plant_id),
  unique (plant_id, external_no)
);
alter table public.wash_formulas enable row level security;
create index wash_formulas_plant_org_idx on public.wash_formulas (plant_id, org_id);
create index wash_formulas_item_plant_idx on public.wash_formulas (item_type_id, plant_id);

-- ── Triggers ──────────────────────────────────────────────────────────────
create trigger item_types_touch_updated_at before update on public.item_types
  for each row execute function app.touch_updated_at();
create trigger item_types_check_languages before insert or update of name_i18n, plant_id on public.item_types
  for each row execute function app.check_languages();
create trigger areas_audit after insert or update on public.areas
  for each row execute function app.audit();
create trigger stations_audit after insert or update on public.stations
  for each row execute function app.audit();
create trigger machines_audit after insert or update on public.machines
  for each row execute function app.audit();
create trigger item_types_audit after insert or update on public.item_types
  for each row execute function app.audit();
create trigger wash_formulas_audit after insert or update on public.wash_formulas
  for each row execute function app.audit();

-- ── §4.6 conversion: the single source of truth ───────────────────────────
-- SECURITY INVOKER: the caller's RLS on item_types applies, so it never reveals another tenant's
-- factors. Returns null when the needed factor is missing (never a guess). piece/pack results are
-- approximate (pieces_per_load is an average); callers flag them.
create function app.to_loads(p_item_type_id uuid, p_qty numeric, p_unit app.qty_unit)
returns numeric language sql stable set search_path = '' as $$
  select case p_unit
           when 'load'   then p_qty
           when 'basket' then p_qty / i.baskets_per_load
           when 'piece'  then p_qty / i.pieces_per_load
           when 'pack'   then p_qty * i.pack_size / i.pieces_per_load
         end
    from public.item_types i
   where i.id = p_item_type_id;
$$;
comment on function app.to_loads(uuid, numeric, app.qty_unit) is
  '§4.6 Converts qty in unit to wash loads for the item. load=qty; basket=qty/baskets_per_load; piece=qty/pieces_per_load; pack=qty*pack_size/pieces_per_load. Null when a factor (or the item) is missing. piece/pack are approximate.';
grant execute on function app.to_loads(uuid, numeric, app.qty_unit) to authenticated, service_role;

-- ── RLS policies (§4.7) ───────────────────────────────────────────────────
create policy areas_select on public.areas for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')) or (select app.is_display(plant_id)));
create policy areas_insert on public.areas for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager}')));
create policy areas_update on public.areas for update to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')))
  with check ((select app.has_role(plant_id, '{owner,manager}')));

create policy stations_select on public.stations for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')) or (select app.is_display(plant_id)));
create policy stations_insert on public.stations for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager}')));
create policy stations_update on public.stations for update to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')))
  with check ((select app.has_role(plant_id, '{owner,manager}')));

create policy machines_select on public.machines for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')) or (select app.is_display(plant_id)));
create policy machines_insert on public.machines for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager}')));
create policy machines_update on public.machines for update to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')))
  with check ((select app.has_role(plant_id, '{owner,manager}')));

create policy item_types_select on public.item_types for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')) or (select app.is_display(plant_id)));
create policy item_types_insert on public.item_types for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager}')));
create policy item_types_update on public.item_types for update to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')))
  with check ((select app.has_role(plant_id, '{owner,manager}')));

create policy wash_formulas_select on public.wash_formulas for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')) or (select app.is_display(plant_id)));
create policy wash_formulas_insert on public.wash_formulas for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager}')));
create policy wash_formulas_update on public.wash_formulas for update to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')))
  with check ((select app.has_role(plant_id, '{owner,manager}')));
