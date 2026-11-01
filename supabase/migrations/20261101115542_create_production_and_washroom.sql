-- M1 · finished goods, crew hours, washer imports + cycles (PRD E1, E4, A5, F1, F3; §4.4; §4.5; §4.7).
-- D8 (meta, option B): §4.7 direct writes exist for M1 with entered_by pinned to the caller.
-- Direct C (and any U) on finished_goods_entries / washer_cycles is REVOKED in M2 once the
-- staff-session write RPCs (record_finished_goods, void_finished_goods, …) exist.

create table public.finished_goods_entries (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null,
  plant_id          uuid not null,
  area_id           uuid not null,                        -- finishing area
  station_id        uuid,                                 -- optional line (Ironer 1, Folding 2)
  shift_instance_id uuid,
  item_type_id      uuid not null,
  queue_item_id     uuid,
  packs             int not null default 0 check (packs between 0 and 10000),
  pack_size_used    int check (pack_size_used between 1 and 10000),
  loose_pieces      int not null default 0 check (loose_pieces between 0 and 100000),
  pieces            int generated always as (packs * coalesce(pack_size_used, 0) + loose_pieces) stored,
  occurred_at       timestamptz not null default now(),
  note              text check (char_length(note) <= 140 and app.is_clean_text(note)),
  source            app.entry_source not null default 'manual',
  entered_by        uuid not null references auth.users(id),
  staff_id          uuid,                                 -- A8: who entered (name + PIN)
  client_id         uuid not null unique,
  voided_at         timestamptz,
  voided_by         uuid references auth.users(id),
  void_reason       text check (char_length(void_reason) <= 200 and app.is_clean_text(void_reason)),
  created_at        timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (staff_id, plant_id) references public.entry_staff(id, plant_id),
  foreign key (area_id, plant_id) references public.areas(id, plant_id),
  foreign key (station_id, plant_id) references public.stations(id, plant_id),
  foreign key (shift_instance_id, area_id) references public.shift_instances(id, area_id),  -- same area
  foreign key (item_type_id, plant_id) references public.item_types(id, plant_id),
  -- Deviation from §4.4: composite (queue_item_id, plant_id) instead of queue_items(id) alone,
  -- so an entry can never point at another tenant's queue item.
  foreign key (queue_item_id, plant_id) references public.queue_items(id, plant_id),
  check (packs = 0 or pack_size_used is not null),
  check (packs + loose_pieces > 0),
  check ((voided_at is null) = (void_reason is null))
);
alter table public.finished_goods_entries enable row level security;
create index fge_shift_item_idx on public.finished_goods_entries (shift_instance_id, item_type_id) where voided_at is null;
create index fge_entered_by_occurred_idx on public.finished_goods_entries (entered_by, occurred_at desc);
create index fge_entered_by_created_idx on public.finished_goods_entries (entered_by, created_at);
create index fge_item_occurred_idx on public.finished_goods_entries (item_type_id, occurred_at) where voided_at is null;
create index fge_plant_org_idx on public.finished_goods_entries (plant_id, org_id);
create index fge_staff_plant_idx on public.finished_goods_entries (staff_id, plant_id);
create index fge_area_plant_idx on public.finished_goods_entries (area_id, plant_id);
create index fge_station_plant_idx on public.finished_goods_entries (station_id, plant_id);
create index fge_shift_area_idx on public.finished_goods_entries (shift_instance_id, area_id);
create index fge_item_plant_idx on public.finished_goods_entries (item_type_id, plant_id);
create index fge_queue_item_plant_idx on public.finished_goods_entries (queue_item_id, plant_id);
create index fge_voided_by_idx on public.finished_goods_entries (voided_by);

create table public.shift_crew_hours (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null,
  plant_id          uuid not null,
  shift_instance_id uuid not null,
  area_id           uuid not null,
  crew_count        int not null check (crew_count between 0 and 200),
  labor_hours       numeric(8,2) not null check (labor_hours between 0 and 2000),
  entered_by        uuid not null references auth.users(id),
  staff_id          uuid,                                 -- A8
  entered_at        timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (staff_id, plant_id) references public.entry_staff(id, plant_id),
  foreign key (shift_instance_id, area_id) references public.shift_instances(id, area_id),  -- same area
  foreign key (area_id, plant_id) references public.areas(id, plant_id),
  unique (shift_instance_id)
);
alter table public.shift_crew_hours enable row level security;
create index shift_crew_hours_plant_org_idx on public.shift_crew_hours (plant_id, org_id);
create index shift_crew_hours_staff_plant_idx on public.shift_crew_hours (staff_id, plant_id);
create index shift_crew_hours_shift_area_idx on public.shift_crew_hours (shift_instance_id, area_id);
create index shift_crew_hours_area_plant_idx on public.shift_crew_hours (area_id, plant_id);
create index shift_crew_hours_entered_by_idx on public.shift_crew_hours (entered_by);

create table public.import_batches (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  source        app.cycle_source not null,
  storage_path  text check (char_length(storage_path) <= 400),
  file_sha256   text check (file_sha256 ~ '^[0-9a-f]{64}$'),
  status        text not null default 'pending'
                check (status in ('pending','previewed','committed','failed')),
  rows_total    int not null default 0,
  rows_inserted int not null default 0,
  rows_skipped  int not null default 0,
  errors        jsonb not null default '[]'::jsonb check (jsonb_typeof(errors) = 'array'),
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  unique (id, plant_id),            -- deviation: target for washer_cycles' composite FK
  unique (plant_id, file_sha256)
);
alter table public.import_batches enable row level security;
create index import_batches_plant_org_idx on public.import_batches (plant_id, org_id);
create index import_batches_created_by_idx on public.import_batches (created_by);

create table public.washer_cycles (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null,
  plant_id          uuid not null,
  area_id           uuid not null,                        -- washroom area (shift lookup is per area)
  machine_id        uuid,
  wash_formula_id   uuid,
  item_type_id      uuid,                                 -- resolved from formula or chosen manually
  shift_instance_id uuid,
  started_at        timestamptz not null,
  ended_at          timestamptz,
  load_count        int not null default 1 check (load_count between 1 and 200),
  source            app.cycle_source not null,
  external_id       text check (char_length(external_id) <= 200),
  import_batch_id   uuid,
  raw               jsonb,                                -- original vendor row (may include weight; unused)
  entered_by        uuid references auth.users(id),
  staff_id          uuid,                                 -- A8; null for Accu-Flow imports
  client_id         uuid unique,
  created_at        timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (staff_id, plant_id) references public.entry_staff(id, plant_id),
  foreign key (area_id, plant_id) references public.areas(id, plant_id),
  foreign key (machine_id, plant_id) references public.machines(id, plant_id),
  foreign key (wash_formula_id, plant_id) references public.wash_formulas(id, plant_id),
  foreign key (item_type_id, plant_id) references public.item_types(id, plant_id),
  foreign key (shift_instance_id, area_id) references public.shift_instances(id, area_id),  -- same area
  -- Deviation from §4.4: composite (import_batch_id, plant_id) instead of import_batches(id) alone.
  foreign key (import_batch_id, plant_id) references public.import_batches(id, plant_id),
  check (ended_at is null or ended_at >= started_at),
  check (item_type_id is not null or wash_formula_id is not null),
  check (source <> 'manual' or client_id is not null),   -- architect N2: manual entries are idempotent
  unique nulls distinct (plant_id, source, external_id)
);
alter table public.washer_cycles enable row level security;
create index washer_cycles_shift_item_idx on public.washer_cycles (shift_instance_id, item_type_id);
create index washer_cycles_item_started_idx on public.washer_cycles (item_type_id, started_at);
create index washer_cycles_entered_by_created_idx on public.washer_cycles (entered_by, created_at);
create index washer_cycles_plant_org_idx on public.washer_cycles (plant_id, org_id);
create index washer_cycles_staff_plant_idx on public.washer_cycles (staff_id, plant_id);
create index washer_cycles_area_plant_idx on public.washer_cycles (area_id, plant_id);
create index washer_cycles_machine_plant_idx on public.washer_cycles (machine_id, plant_id);
create index washer_cycles_formula_plant_idx on public.washer_cycles (wash_formula_id, plant_id);
create index washer_cycles_item_plant_idx on public.washer_cycles (item_type_id, plant_id);
create index washer_cycles_shift_area_idx on public.washer_cycles (shift_instance_id, area_id);
create index washer_cycles_batch_plant_idx on public.washer_cycles (import_batch_id, plant_id);

-- ── §4.5 trigger functions ────────────────────────────────────────────────
-- Extra (b): validates on INSERT, and on UPDATE only when packs / pack_size_used / loose_pieces
-- change, so voiding an old row never fails after the item's count mode changed.
create function app.apply_count_mode()
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
    from public.item_types i where i.id = new.item_type_id;
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
  '§4.5 BEFORE INSERT / UPDATE OF packs, pack_size_used, loose_pieces on finished_goods_entries: unit items need packs=0 and no pack size (COUNT_MODE_MISMATCH); pack items copy the item''s pack_size when packs>0 and none was given.';

-- Fallback only: write RPCs set shift_instance_id with app.resolve_entry_shift() (A8).
create function app.set_shift_instance()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.shift_instance_id is null then
    if tg_table_name = 'finished_goods_entries' then
      new.shift_instance_id := app.shift_instance_at(new.area_id, new.occurred_at);
    elsif tg_table_name = 'washer_cycles' then
      new.shift_instance_id := app.shift_instance_at(new.area_id, new.started_at);
    end if;
  end if;
  return new;   -- still null = off-shift (counted in day totals, D9)
end;
$$;
comment on function app.set_shift_instance() is
  '§4.5 BEFORE INSERT fallback on finished_goods_entries (occurred_at) and washer_cycles (started_at): sets the row''s area instance containing the timestamp (skipped excluded) when shift_instance_id is null; null = off-shift.';

create function app.resolve_item_from_formula()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.item_type_id is null and new.wash_formula_id is not null then
    select f.item_type_id into new.item_type_id
      from public.wash_formulas f
     where f.id = new.wash_formula_id and f.plant_id = new.plant_id;
  end if;
  return new;
end;
$$;
comment on function app.resolve_item_from_formula() is
  '§4.5 BEFORE INSERT/UPDATE on washer_cycles: copies the wash formula''s item_type_id when item_type_id is null.';

create function app.throttle_writes()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_recent int;
begin
  -- Security M2: no cross-tenant oracle; RLS rejects rows on plants the caller has no role on.
  if (select auth.uid()) is not null and not app.has_role(new.plant_id, '{owner,manager,lead,viewer}') then
    return new;
  end if;
  if new.entered_by is null then
    return new;   -- system imports (service role) are not throttled
  end if;
  if tg_table_name = 'finished_goods_entries' then
    select count(*) into v_recent from public.finished_goods_entries t
     where t.entered_by = new.entered_by and t.created_at > pg_catalog.now() - interval '60 seconds';
  elsif tg_table_name = 'washer_cycles' then
    select count(*) into v_recent from public.washer_cycles t
     where t.entered_by = new.entered_by and t.created_at > pg_catalog.now() - interval '60 seconds';
  end if;
  if v_recent >= 120 then
    raise exception 'RATE_LIMITED' using detail = 'more than 120 inserts in 60 seconds';
  end if;
  return new;
end;
$$;
comment on function app.throttle_writes() is
  '§4.5 BEFORE INSERT on finished_goods_entries, washer_cycles: more than 120 inserts by the same user in 60 s raises RATE_LIMITED.';

-- ── Triggers ──────────────────────────────────────────────────────────────
create trigger fge_throttle before insert on public.finished_goods_entries
  for each row execute function app.throttle_writes();
create trigger fge_apply_count_mode before insert or update of packs, pack_size_used, loose_pieces
  on public.finished_goods_entries for each row execute function app.apply_count_mode();
create trigger fge_set_shift_instance before insert on public.finished_goods_entries
  for each row execute function app.set_shift_instance();
create trigger fge_prevent_delete before delete on public.finished_goods_entries
  for each row execute function app.prevent_delete();
create trigger fge_prevent_truncate before truncate on public.finished_goods_entries
  for each statement execute function app.prevent_delete();
create trigger fge_audit after insert or update on public.finished_goods_entries
  for each row execute function app.audit();

create trigger washer_cycles_throttle before insert on public.washer_cycles
  for each row execute function app.throttle_writes();
create trigger washer_cycles_resolve_item before insert or update of item_type_id, wash_formula_id
  on public.washer_cycles for each row execute function app.resolve_item_from_formula();
create trigger washer_cycles_set_shift_instance before insert on public.washer_cycles
  for each row execute function app.set_shift_instance();
create trigger washer_cycles_prevent_delete before delete on public.washer_cycles
  for each row execute function app.prevent_delete();
create trigger washer_cycles_prevent_truncate before truncate on public.washer_cycles
  for each statement execute function app.prevent_delete();
create trigger washer_cycles_audit after insert or update on public.washer_cycles
  for each row execute function app.audit();

create trigger shift_crew_hours_audit after insert or update on public.shift_crew_hours
  for each row execute function app.audit();

-- ── RLS policies (§4.7) ───────────────────────────────────────────────────
-- finished_goods_entries: owner/manager R C; lead, viewer R; display none (totals via feed).
-- D8: NO direct UPDATE (voids go through void_finished_goods in M2); the grant is revoked too.
revoke update, delete, truncate on public.finished_goods_entries from anon, authenticated;
create policy fge_select on public.finished_goods_entries for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')));
create policy fge_insert on public.finished_goods_entries for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager}')) and entered_by = (select auth.uid())
              and voided_at is null and voided_by is null);   -- security L4: no pre-voided rows

-- shift_crew_hours: owner/manager R C U; lead, viewer R.
create policy shift_crew_hours_select on public.shift_crew_hours for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')));
create policy shift_crew_hours_insert on public.shift_crew_hours for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager}')) and entered_by = (select auth.uid()));
create policy shift_crew_hours_update on public.shift_crew_hours for update to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')))
  with check ((select app.has_role(plant_id, '{owner,manager}')));

-- import_batches: owner/manager/lead R C; viewer R.
create policy import_batches_select on public.import_batches for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')));
create policy import_batches_insert on public.import_batches for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager,lead}')) and created_by = (select auth.uid()));

-- washer_cycles: owner/manager/lead R C (manual only, D8); viewer R; display none.
create policy washer_cycles_select on public.washer_cycles for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')));
create policy washer_cycles_insert on public.washer_cycles for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager,lead}'))
              and entered_by = (select auth.uid())
              and source = 'manual'
              and import_batch_id is null);
