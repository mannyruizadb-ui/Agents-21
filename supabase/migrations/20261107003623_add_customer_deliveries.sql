-- Outside-customer deliveries (owner 2026-11-06, B): what AA Linen dropped off, entered by an owner or a
-- manager with name + PIN (A8, same staff-session mechanism as record_soil_estimate). Every line also
-- becomes a queue item at the BOTTOM of the washroom queue (normal work; only owners reorder), tagged with
-- the customer, unit 'bin', qty = bins. This is a new manager path to add (non-rewash) queue items: the
-- owner's decision 2026-11-06.
--
-- * customer_deliveries: one row per drop-off (customer, delivered_at, entered_by + staff_id, client_id,
--   note ≤ 200, voided_at/by/reason). Append-only: never deleted; only the void columns may be set, once
--   (no void RPC yet). RPC-only (RLS on, no client policies or grants).
-- * customer_delivery_lines: wash group (must be a group of the delivery's customer, same plant) + bins in
--   quarters (0.25–50), loads = app.to_loads(bins in 'bin') snapshotted at insert (null when the group has
--   no loads_per_bin yet: never a guess), and the queue item it created. Append-only, RPC-only.
-- * record_customer_delivery(...) → customer_delivery_result {delivery_id, queue_item_ids[], duplicate}.
-- * get_customer_deliveries(...): OWNER only (with entered_by_name, app.person_name). Managers: refused
--   (NOT_AUTHORIZED). Simplest rule consistent with "managers see the current shift only": a manager sees
--   what a delivery did through the queue (the items are open washroom work, which the queue already
--   shows them) and gets the ids back from record_customer_delivery; no delivery history.
-- * Alert customer_delivery (owner information kind, default push): written by record_customer_delivery.
--   Payload (customer, delivered_at, lines: group + bins + loads; no names, no note) is in
--   20261107003625.

create type public.customer_delivery_result as (
  delivery_id    uuid,
  queue_item_ids uuid[],
  duplicate      boolean
);
comment on type public.customer_delivery_result is
  'record_customer_delivery result: the delivery id, the queue items it created (in line order), and duplicate = true for an idempotent retry.';

-- ── customer_deliveries ───────────────────────────────────────────────────
create table public.customer_deliveries (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null,
  plant_id     uuid not null,
  customer_id  uuid not null,
  delivered_at timestamptz not null default now(),
  entered_by   uuid not null references auth.users(id),
  staff_id     uuid,
  client_id    uuid not null unique,
  note         text check (char_length(note) between 1 and 200 and app.is_clean_text(note)),
  voided_at    timestamptz,
  voided_by    uuid references auth.users(id),
  void_reason  text check (char_length(void_reason) between 1 and 200 and app.is_clean_text(void_reason)),
  created_at   timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (customer_id, plant_id) references public.customers(id, plant_id),
  foreign key (staff_id, plant_id) references public.entry_staff(id, plant_id),
  unique (id, plant_id),
  constraint customer_deliveries_void_consistent
    check ((voided_at is null) = (voided_by is null) and (voided_at is null) = (void_reason is null))
);
alter table public.customer_deliveries enable row level security;
create index customer_deliveries_plant_org_idx on public.customer_deliveries (plant_id, org_id);
create index customer_deliveries_customer_plant_idx on public.customer_deliveries (customer_id, plant_id);
create index customer_deliveries_staff_plant_idx on public.customer_deliveries (staff_id, plant_id);
create index customer_deliveries_entered_by_idx on public.customer_deliveries (entered_by);
create index customer_deliveries_voided_by_idx on public.customer_deliveries (voided_by);
create index customer_deliveries_plant_delivered_idx on public.customer_deliveries (plant_id, delivered_at desc);
comment on table public.customer_deliveries is
  'Owner 2026-11-06 (B): an outside customer''s drop-off (e.g. AA Linen bins). Written only by record_customer_delivery (owner/manager + name + PIN); read only by get_customer_deliveries (owner). RLS on, no client policies or grants. Append-only: never deleted; only the void columns may be set, once.';
revoke all on public.customer_deliveries from anon, authenticated;

create function app.guard_customer_delivery_update()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- Only voiding, once: every other column stays as written.
  if old.voided_at is not null
     or (to_jsonb(new) - 'voided_at' - 'voided_by' - 'void_reason')
        is distinct from (to_jsonb(old) - 'voided_at' - 'voided_by' - 'void_reason') then
    raise exception 'VALIDATION_FAILED' using detail = 'customer_deliveries is append-only: only an unvoided delivery can be voided; nothing else changes';
  end if;
  return new;
end;
$$;
comment on function app.guard_customer_delivery_update() is
  'Owner 2026-11-06 (B): customer_deliveries is append-only; an update may only void a delivery that is not voided yet. Trigger.';
revoke all on function app.guard_customer_delivery_update() from public, anon, authenticated;
create trigger customer_deliveries_guard_update before update on public.customer_deliveries
  for each row execute function app.guard_customer_delivery_update();
create trigger customer_deliveries_prevent_delete before delete on public.customer_deliveries
  for each row execute function app.prevent_delete();
create trigger customer_deliveries_prevent_truncate before truncate on public.customer_deliveries
  for each statement execute function app.prevent_delete();
create trigger customer_deliveries_audit after insert or update on public.customer_deliveries
  for each row execute function app.audit();

-- ── customer_delivery_lines ───────────────────────────────────────────────
create table public.customer_delivery_lines (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  delivery_id   uuid not null,
  line_no       smallint not null check (line_no between 1 and 30),
  wash_group_id uuid not null,
  bins          numeric(6,2) not null check (bins between 0.25 and 50 and bins * 4 = trunc(bins * 4)),
  loads         numeric(10,3) check (loads >= 0),
  queue_item_id uuid,
  created_at    timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (delivery_id, plant_id) references public.customer_deliveries(id, plant_id),
  foreign key (wash_group_id, plant_id) references public.wash_groups(id, plant_id),
  foreign key (queue_item_id, plant_id) references public.queue_items(id, plant_id),
  unique (delivery_id, line_no),
  unique (delivery_id, wash_group_id)
);
alter table public.customer_delivery_lines enable row level security;
create index customer_delivery_lines_plant_org_idx on public.customer_delivery_lines (plant_id, org_id);
create index customer_delivery_lines_delivery_plant_idx on public.customer_delivery_lines (delivery_id, plant_id);
create index customer_delivery_lines_group_plant_idx on public.customer_delivery_lines (wash_group_id, plant_id);
create index customer_delivery_lines_queue_plant_idx on public.customer_delivery_lines (queue_item_id, plant_id);
comment on table public.customer_delivery_lines is
  'Owner 2026-11-06 (B): one wash group of a customer delivery: bins in quarters (0.25–50), loads = app.to_loads(bins, ''bin'') at insert (null = the group has no loads_per_bin yet), and the washroom queue item it created. The group must belong to the delivery''s customer (trigger). Append-only, RPC-only (RLS on, no client policies or grants).';
revoke all on public.customer_delivery_lines from anon, authenticated;

create function app.check_customer_delivery_line()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_customer uuid;
begin
  select d.customer_id into v_customer from public.customer_deliveries d
   where d.id = new.delivery_id and d.plant_id = new.plant_id;
  if v_customer is null then
    return new;                                    -- the delivery FK reports it
  end if;
  if not exists (select 1 from public.wash_groups g
                  where g.id = new.wash_group_id and g.plant_id = new.plant_id and g.customer_id = v_customer) then
    raise exception 'VALIDATION_FAILED' using detail = 'wash_group_id: not a wash group of the delivery''s customer';
  end if;
  new.loads := app.to_loads(new.wash_group_id, null, new.bins, 'bin');   -- snapshot; null = no factor
  return new;
end;
$$;
comment on function app.check_customer_delivery_line() is
  'Owner 2026-11-06 (B): BEFORE INSERT on customer_delivery_lines: the wash group must belong to the delivery''s customer (same plant); loads := app.to_loads(bins, ''bin'') (null when the factor is missing). Trigger.';
revoke all on function app.check_customer_delivery_line() from public, anon, authenticated;
create trigger customer_delivery_lines_check before insert on public.customer_delivery_lines
  for each row execute function app.check_customer_delivery_line();
create trigger customer_delivery_lines_prevent_mutation before update or delete on public.customer_delivery_lines
  for each row execute function app.prevent_mutation();
create trigger customer_delivery_lines_prevent_truncate before truncate on public.customer_delivery_lines
  for each statement execute function app.prevent_delete();
create trigger customer_delivery_lines_audit after insert on public.customer_delivery_lines
  for each row execute function app.audit();

-- ── record_customer_delivery ──────────────────────────────────────────────
create function app.customer_delivery_result(p_delivery_id uuid, p_duplicate boolean)
returns public.customer_delivery_result language sql stable security definer set search_path = '' as $$
  select row(p_delivery_id,
             coalesce((select pg_catalog.array_agg(l.queue_item_id order by l.line_no)
                         from public.customer_delivery_lines l where l.delivery_id = p_delivery_id), '{}'),
             p_duplicate)::public.customer_delivery_result;
$$;
comment on function app.customer_delivery_result(uuid, boolean) is
  'Owner 2026-11-06 (B): builds record_customer_delivery''s result (queue item ids in line order). Internal.';
revoke all on function app.customer_delivery_result(uuid, boolean) from public, anon, authenticated;

create function public.record_customer_delivery(
  p_plant_id         uuid,
  p_customer_id      uuid,
  p_lines            jsonb,
  p_client_id        uuid,
  p_staff_session_id uuid,
  p_note             text default null,
  p_entered_at       timestamptz default null)
returns public.customer_delivery_result language plpgsql volatile security definer set search_path = '' as $$
declare
  v_plant    record;
  v_existing record;
  v_now      timestamptz := pg_catalog.now();
  v_ts       timestamptz;
  v_line     record;
  v_group    uuid;
  v_bins     numeric;
  v_groups   uuid[] := '{}';
  v_bins_all numeric[] := '{}';
  v_area     uuid;
  v_areas    int;
  v_note     text;
  v_staff    uuid;
  v_del      uuid;
  v_q        uuid;
begin
  -- Role check FIRST: a missing plant and another tenant's plant give the same answer.
  select p.id, p.org_id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant.id is null or not app.has_role(v_plant.id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'record_customer_delivery requires owner or manager on the plant';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  -- Idempotency before the time window and the staff session: an offline retry returns the saved delivery.
  select d.id, d.plant_id into v_existing from public.customer_deliveries d where d.client_id = p_client_id;
  if v_existing.id is not null then
    if v_existing.plant_id = v_plant.id then
      return app.customer_delivery_result(v_existing.id, true);
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  v_ts := coalesce(p_entered_at, v_now);
  if v_ts < v_now - interval '6 hours' or v_ts > v_now + interval '1 minute' then
    raise exception 'OUT_OF_RANGE_TIMESTAMP' using detail = 'p_entered_at: must be within the last 6 hours (up to 1 minute ahead)';
  end if;
  if p_customer_id is null or not exists (select 1 from public.customers c
                                           where c.id = p_customer_id and c.plant_id = v_plant.id and c.active) then
    raise exception 'VALIDATION_FAILED' using detail = 'customer_id: no active customer with this id in the plant';
  end if;
  if p_lines is null or pg_catalog.jsonb_typeof(p_lines) <> 'array'
     or pg_catalog.jsonb_array_length(p_lines) not between 1 and 30 then
    raise exception 'VALIDATION_FAILED' using detail = 'p_lines: an array of 1–30 {wash_group_id, bins}';
  end if;
  for v_line in select e.val, e.ord from pg_catalog.jsonb_array_elements(p_lines) with ordinality e(val, ord) loop
    if pg_catalog.jsonb_typeof(v_line.val) <> 'object'
       or exists (select 1 from pg_catalog.jsonb_object_keys(v_line.val) k where k not in ('wash_group_id', 'bins'))
       or pg_catalog.jsonb_typeof(v_line.val -> 'wash_group_id') is distinct from 'string'
       or (v_line.val ->> 'wash_group_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or pg_catalog.jsonb_typeof(v_line.val -> 'bins') is distinct from 'number' then
      raise exception 'VALIDATION_FAILED' using detail = format('p_lines[%s]: {wash_group_id: uuid, bins: number}', v_line.ord);
    end if;
    v_group := (v_line.val ->> 'wash_group_id')::uuid;
    v_bins := (v_line.val ->> 'bins')::numeric;
    if v_bins < 0.25 or v_bins > 50 or v_bins * 4 <> pg_catalog.trunc(v_bins * 4) then
      raise exception 'VALIDATION_FAILED' using detail = format('p_lines[%s].bins: 0.25–50 in quarters', v_line.ord);
    end if;
    if not exists (select 1 from public.wash_groups g
                    where g.id = v_group and g.plant_id = v_plant.id and g.active and g.customer_id = p_customer_id) then
      raise exception 'VALIDATION_FAILED' using detail = format('p_lines[%s].wash_group_id: not an active wash group of this customer', v_line.ord);
    end if;
    if v_group = any (v_groups) then
      raise exception 'VALIDATION_FAILED' using detail = format('p_lines[%s].wash_group_id: listed twice', v_line.ord);
    end if;
    v_groups := v_groups || v_group;
    v_bins_all := v_bins_all || v_bins;
  end loop;
  select count(*), min(a.id::text)::uuid into v_areas, v_area
    from public.areas a where a.plant_id = v_plant.id and a.kind = 'washroom' and a.active;
  if v_areas <> 1 then
    raise exception 'VALIDATION_FAILED' using detail = 'the plant needs exactly one active washroom area for deliveries';
  end if;
  v_note := app.clean_note(p_note, 200, 'note');
  v_staff := app.use_staff_session(p_staff_session_id, v_plant.id);

  -- Serialize with the queue RPCs and the washer taps of the area (positions).
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('queue:' || v_area::text, 0));
  insert into public.customer_deliveries as d (org_id, plant_id, customer_id, delivered_at, entered_by, staff_id, client_id, note)
  values (v_plant.org_id, v_plant.id, p_customer_id, v_ts, (select auth.uid()), v_staff, p_client_id, v_note)
  on conflict (client_id) do nothing
  returning d.id into v_del;
  if v_del is null then   -- a concurrent retry won the race
    select d.id into v_del from public.customer_deliveries d where d.client_id = p_client_id and d.plant_id = v_plant.id;
    if v_del is null then
      raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
    end if;
    return app.customer_delivery_result(v_del, true);
  end if;

  for i in 1 .. pg_catalog.cardinality(v_groups) loop
    -- Normal (not rush, not rewash) work at the bottom of the normal items; customer_id by trigger.
    insert into public.queue_items as q (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position,
                                         is_rush, note, created_by, client_id, assigned_machine_id, is_rewash)
    values (v_plant.org_id, v_plant.id, v_area, v_groups[i], null, v_bins_all[i], 'bin',
            app.queue_edge_position(v_area, false, false, null),
            false, null, (select auth.uid()), gen_random_uuid(), null, false)
    returning q.id into v_q;
    insert into public.customer_delivery_lines (org_id, plant_id, delivery_id, line_no, wash_group_id, bins, queue_item_id)
    values (v_plant.org_id, v_plant.id, v_del, i, v_groups[i], v_bins_all[i], v_q);
  end loop;

  perform app.raise_owner_alert(v_plant.org_id, v_plant.id, 'customer_delivery', v_del);
  return app.customer_delivery_result(v_del, false);
end;
$$;
comment on function public.record_customer_delivery(uuid, uuid, jsonb, uuid, uuid, text, timestamptz) is
  'Owner 2026-11-06 (B) RPC (owner or manager of the plant + staff session = name + PIN, A8; definer, role check first, no oracle): records an outside customer''s delivery. p_lines: 1–30 {wash_group_id, bins}: active wash groups of p_customer_id (an active customer of the plant), each once, bins 0.25–50 in quarters. p_note ≤ 200. p_entered_at = delivered_at (device time of an offline entry; default now; within [now − 6 h, now + 1 min], else OUT_OF_RANGE_TIMESTAMP). Writes customer_deliveries + customer_delivery_lines (loads = app.to_loads, null without loads_per_bin) and, per line, one washroom queue item at the BOTTOM of the normal items (unit bin, qty = bins, not rush, not rewash, not assigned, customer_id = the customer), then a customer_delivery owner alert. Idempotent on p_client_id, checked before the time window and the session (duplicate = true; another plant''s client_id → VALIDATION_FAILED). Returns customer_delivery_result {delivery_id, queue_item_ids (line order), duplicate}. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, OUT_OF_RANGE_TIMESTAMP, STAFF_SESSION_REQUIRED.';
revoke all on function public.record_customer_delivery(uuid, uuid, jsonb, uuid, uuid, text, timestamptz) from public, anon;
grant execute on function public.record_customer_delivery(uuid, uuid, jsonb, uuid, uuid, text, timestamptz) to authenticated, service_role;

-- ── get_customer_deliveries (owner only) ──────────────────────────────────
create function public.get_customer_deliveries(
  p_plant_id    uuid,
  p_since       timestamptz default null,
  p_customer_id uuid default null)
returns table (delivery_id uuid, customer_id uuid, customer_name text, customer_name_i18n jsonb,
               delivered_at timestamptz, note text, voided boolean, voided_at timestamptz, void_reason text,
               entered_by_name text, lines jsonb)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_plant uuid;
  v_from  timestamptz;
begin
  select p.id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant is null or not app.has_role(v_plant, '{owner}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_customer_deliveries requires owner on the plant';
  end if;
  v_from := greatest(coalesce(p_since, pg_catalog.now() - interval '7 days'), pg_catalog.now() - interval '31 days');
  return query
  select d.id, d.customer_id, c.name, c.name_i18n, d.delivered_at, d.note, d.voided_at is not null,
         d.voided_at, d.void_reason, app.person_name(d.entered_by, d.staff_id, d.plant_id),
         coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                     'line_id', l.id, 'wash_group_id', l.wash_group_id, 'wash_group_name', g.name,
                     'wash_group_name_i18n', g.name_i18n, 'bins', l.bins, 'loads', l.loads,
                     'queue_item_id', l.queue_item_id, 'queue_status', q.status) order by l.line_no)
                     from public.customer_delivery_lines l
                     join public.wash_groups g on g.id = l.wash_group_id and g.plant_id = l.plant_id
                     left join public.queue_items q on q.id = l.queue_item_id and q.plant_id = l.plant_id
                    where l.delivery_id = d.id and l.plant_id = d.plant_id), '[]'::jsonb)
    from public.customer_deliveries d
    join public.customers c on c.id = d.customer_id and c.plant_id = d.plant_id
   where d.plant_id = v_plant
     and d.delivered_at > v_from
     and (p_customer_id is null or d.customer_id = p_customer_id)
   order by d.delivered_at desc, d.id desc
   limit 500;
end;
$$;
comment on function public.get_customer_deliveries(uuid, timestamptz, uuid) is
  'Owner 2026-11-06 (B) read (OWNER only; definer, role check first; managers NOT_AUTHORIZED — they see a delivery''s work in the queue): the plant''s customer deliveries delivered after p_since (default 7 days ago; never more than 31 days back), optionally one customer, newest first, at most 500. Columns: delivery_id, customer_id, customer_name, customer_name_i18n, delivered_at, note, voided, voided_at, void_reason, entered_by_name (entry staff name for the PIN, else the account name; app.person_name), lines (jsonb [{line_id, wash_group_id, wash_group_name, wash_group_name_i18n, bins, loads (null = no loads_per_bin), queue_item_id, queue_status}] in line order). No per-person totals. Errors: NOT_AUTHORIZED.';
revoke all on function public.get_customer_deliveries(uuid, timestamptz, uuid) from public, anon;
grant execute on function public.get_customer_deliveries(uuid, timestamptz, uuid) to authenticated, service_role;
