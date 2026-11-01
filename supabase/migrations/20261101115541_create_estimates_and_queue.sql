-- M1 · soil estimates (append-only) + work queue (PRD B1, C1–C4; §4.4; §4.5; §4.7; §4.8).

create table public.soil_estimates (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  item_type_id  uuid not null,
  qty           numeric(10,2) not null check (qty >= 0 and qty <= 10000),
  unit          app.qty_unit not null check (unit in ('load','basket')),
  note          text check (char_length(note) <= 280 and app.is_clean_text(note)),
  entered_by    uuid not null references auth.users(id),
  staff_id      uuid,                                     -- A8: who entered (name + PIN)
  entered_at    timestamptz not null default now(),
  client_id     uuid not null unique,                     -- idempotency
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (staff_id, plant_id) references public.entry_staff(id, plant_id),
  foreign key (item_type_id, plant_id) references public.item_types(id, plant_id)
);
alter table public.soil_estimates enable row level security;
create index soil_estimates_current_idx on public.soil_estimates (plant_id, item_type_id, entered_at desc);
create index soil_estimates_plant_org_idx on public.soil_estimates (plant_id, org_id);
create index soil_estimates_item_plant_idx on public.soil_estimates (item_type_id, plant_id);
create index soil_estimates_staff_plant_idx on public.soil_estimates (staff_id, plant_id);
create index soil_estimates_entered_by_idx on public.soil_estimates (entered_by);

create table public.queue_items (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  area_id       uuid not null,
  item_type_id  uuid not null,
  qty           numeric(10,2) not null check (qty > 0 and qty <= 100000),
  unit          app.qty_unit not null,
  position      numeric(30,15) not null,                  -- fractional ordering
  is_rush       boolean not null default false,
  status        app.queue_status not null default 'queued',
  note          text check (char_length(note) <= 140 and app.is_clean_text(note)),
  version       int not null default 1,                   -- optimistic concurrency
  created_by    uuid not null references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references auth.users(id),
  updated_by_staff_id uuid,                               -- A8
  started_at    timestamptz,
  completed_at  timestamptz,
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (updated_by_staff_id, plant_id) references public.entry_staff(id, plant_id),
  foreign key (area_id, plant_id) references public.areas(id, plant_id),
  foreign key (item_type_id, plant_id) references public.item_types(id, plant_id),
  unique (id, plant_id),            -- deviation: target for finished_goods_entries' composite FK
  check (completed_at is null or started_at is null or completed_at >= started_at),
  check ((status = 'done') = (completed_at is not null))
);
alter table public.queue_items enable row level security;
create index queue_items_board_idx on public.queue_items (area_id, position) where status in ('queued','in_progress');
create index queue_items_plant_org_idx on public.queue_items (plant_id, org_id);
create index queue_items_area_plant_idx on public.queue_items (area_id, plant_id);
create index queue_items_item_plant_idx on public.queue_items (item_type_id, plant_id);
create index queue_items_staff_plant_idx on public.queue_items (updated_by_staff_id, plant_id);
create index queue_items_created_by_idx on public.queue_items (created_by);
create index queue_items_updated_by_idx on public.queue_items (updated_by);

-- ── §4.5 trigger functions ────────────────────────────────────────────────
create function app.check_estimate_unit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.unit = 'basket' and not exists (
       select 1 from public.item_types i
        where i.id = new.item_type_id and i.allow_basket_estimates) then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: basket estimates are not allowed for this item';
  end if;
  return new;
end;
$$;
comment on function app.check_estimate_unit() is
  '§4.5 BEFORE INSERT on soil_estimates: rejects unit basket unless the item allows basket estimates (VALIDATION_FAILED).';

create function app.prevent_mutation()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'VALIDATION_FAILED' using detail = format('%s is append-only: %s is not allowed', tg_table_name, lower(tg_op));
end;
$$;
comment on function app.prevent_mutation() is '§4.5 BEFORE UPDATE/DELETE on append-only tables (soil_estimates): always raises.';

create function app.prevent_delete()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'VALIDATION_FAILED' using detail = format('%s rows are never deleted: void or cancel instead', tg_table_name);
end;
$$;
comment on function app.prevent_delete() is '§4.5 BEFORE DELETE on finished_goods_entries, washer_cycles, queue_items: always raises (void/cancel instead).';

-- Allowed transitions (§4.9): queued → in_progress → done; queued/in_progress → cancelled.
create function app.bump_queue_version()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.version    := old.version + 1;
  new.updated_at := pg_catalog.now();
  new.updated_by := coalesce((select auth.uid()), new.updated_by);
  if new.status is distinct from old.status then
    if (old.status, new.status) in (('queued','in_progress'), ('in_progress','done'),
                                    ('queued','cancelled'), ('in_progress','cancelled')) then
      if new.status = 'in_progress' then
        new.started_at := coalesce(new.started_at, pg_catalog.now());
      elsif new.status = 'done' then
        new.completed_at := coalesce(new.completed_at, pg_catalog.now());
      end if;
    else
      raise exception 'INVALID_STATUS_TRANSITION' using detail = format('%s → %s', old.status, new.status);
    end if;
  end if;
  return new;
end;
$$;
comment on function app.bump_queue_version() is
  '§4.5 BEFORE UPDATE on queue_items: version+1, updated_at/updated_by, started_at/completed_at on transitions; raises INVALID_STATUS_TRANSITION for anything but queued→in_progress→done or queued/in_progress→cancelled.';

-- ── Triggers ──────────────────────────────────────────────────────────────
create trigger soil_estimates_check_unit before insert on public.soil_estimates
  for each row execute function app.check_estimate_unit();
create trigger soil_estimates_prevent_mutation before update or delete on public.soil_estimates
  for each row execute function app.prevent_mutation();
create trigger soil_estimates_audit after insert on public.soil_estimates
  for each row execute function app.audit();
create trigger queue_items_bump_version before update on public.queue_items
  for each row execute function app.bump_queue_version();
create trigger queue_items_prevent_delete before delete on public.queue_items
  for each row execute function app.prevent_delete();
create trigger queue_items_audit after insert or update on public.queue_items
  for each row execute function app.audit();

-- ── Realtime (only queue_items, soil_estimates, display_messages) ─────────
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.soil_estimates, public.queue_items;
  end if;
end;
$$;

-- ── RLS policies (§4.7) ───────────────────────────────────────────────────
-- soil_estimates: owner/manager/lead R C; viewer R; display R (whole plant). Append-only.
-- D8-style direct insert for M1; it is revoked in M2 once update_soil_estimates (staff session) exists.
create policy soil_estimates_select on public.soil_estimates for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}')) or (select app.is_display(plant_id)));
create policy soil_estimates_insert on public.soil_estimates for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager,lead}')) and entered_by = (select auth.uid()));

-- queue_items: owner/manager R C U; lead R (status via RPC in M2); viewer R; display R own area (D13).
create policy queue_items_select on public.queue_items for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}'))
         or ((select app.is_display(plant_id)) and area_id = (select (app.my_device()).area_id)));
create policy queue_items_insert on public.queue_items for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager}')) and created_by = (select auth.uid()));
create policy queue_items_update on public.queue_items for update to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')))
  with check ((select app.has_role(plant_id, '{owner,manager}')));
