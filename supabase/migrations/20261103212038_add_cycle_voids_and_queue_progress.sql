-- M2 pilot write path, part 1: schema additions the write RPCs need (owner decision 2026-11-03:
-- pilot without TVs). Additive only: new nullable/defaulted columns, one trigger, view filters.
--
-- 1. washer_cycles
--    * queue_item_id: the queue item a washer start-tap ran (null = off-queue load). Composite FK
--      (queue_item_id, plant_id) → queue_items(id, plant_id), so it never points at another tenant.
--      undo_washer_load uses it to give the load back to the queue item.
--    * voided_at / voided_by / void_reason: a mistaken tap is VOIDED (undo_washer_load), never deleted.
--      Every report view below excludes voided cycles.
--    * production_date: snapshot of the row's production day at insert (security carry-forward:
--      "store production_date on off-shift rows"). Without it, an off-shift row's day was computed
--      at report time from plants.production_day_start, so editing that setting moved past off-shift
--      rows to another day. Set for EVERY row by trigger (client value ignored).
-- 2. finished_goods_entries.production_date: same snapshot, same trigger.
-- 3. queue_items.loads_started: loads started from this item by washer start-taps (start_washer_load
--    +1, undo_washer_load −1). Remaining loads = loads_needed − loads_started, where loads_needed =
--    ceil(app.to_loads(qty)) for 'load' and 'basket' units (null = no conversion, never auto-done).
--    Model chosen over decrementing qty: qty keeps what the owner asked for (history), and undo is exact.
-- 4. wash_groups.ships_next_morning: the group is daily-turnaround goods that ship on the 06:00 trucks
--    (owner 2026-11-02, research/washroom-patterns.md). Values are owner data, set in seed / the app.
-- 5. app.bump_queue_version: an UNDO of a washer tap may reopen a done item (done → in_progress) or
--    return an untouched item to the queue (in_progress/done → queued). Allowed only in the same UPDATE
--    that LOWERS loads_started (security review L2: no session setting, which any SQL session could set).
--    Only undo_washer_load lowers loads_started; clients have no queue UPDATE privilege.

-- ── 1. washer_cycles ──────────────────────────────────────────────────────
alter table public.washer_cycles
  add column queue_item_id uuid,
  add column voided_at timestamptz,
  add column voided_by uuid references auth.users(id),
  add column void_reason text
    constraint washer_cycles_void_reason_text check (char_length(void_reason) between 1 and 200 and app.is_clean_text(void_reason)),
  add column production_date date,
  add constraint washer_cycles_queue_item_fkey foreign key (queue_item_id, plant_id) references public.queue_items(id, plant_id),
  add constraint washer_cycles_void_consistent check ((voided_at is null) = (void_reason is null) and (voided_at is null) = (voided_by is null));
create index washer_cycles_queue_item_plant_idx on public.washer_cycles (queue_item_id, plant_id);
create index washer_cycles_voided_by_idx on public.washer_cycles (voided_by);
-- Washroom board: latest live cycle per machine.
create index washer_cycles_machine_started_idx on public.washer_cycles (machine_id, started_at desc) where voided_at is null;
comment on column public.washer_cycles.queue_item_id is
  'M2: the queue item this load was started from (start_washer_load); null = off-queue load. Same plant (composite FK).';
comment on column public.washer_cycles.voided_at is
  'M2: set by undo_washer_load (within 30 min of the tap). Voided cycles are excluded from every report; never deleted.';
comment on column public.washer_cycles.production_date is
  'Production day of the row, snapshotted at insert by app.set_row_production_date (shift instance''s production_date, else app.production_date(started_at)). Client value ignored.';

-- ── 2. finished_goods_entries ─────────────────────────────────────────────
alter table public.finished_goods_entries add column production_date date;
comment on column public.finished_goods_entries.production_date is
  'Production day of the row, snapshotted at insert by app.set_row_production_date (shift instance''s production_date, else app.production_date(occurred_at)). Client value ignored.';

create function app.set_row_production_date()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_ts timestamptz;
begin
  -- Separate branches: a plpgsql expression naming new.started_at fails on a table without it.
  if tg_table_name = 'washer_cycles' then
    v_ts := new.started_at;
  else
    v_ts := new.occurred_at;
  end if;
  -- Lookups are filtered by the row's own plant (H1); a foreign or missing reference is left to the FKs.
  -- Nothing here raises, so there is no error-code oracle.
  new.production_date := coalesce(
    (select si.production_date from public.shift_instances si
      where si.id = new.shift_instance_id and si.plant_id = new.plant_id),
    (select app.production_date(v_ts, p.timezone, p.production_day_start) from public.plants p
      where p.id = new.plant_id));
  return new;
end;
$$;
comment on function app.set_row_production_date() is
  'BEFORE INSERT on washer_cycles / finished_goods_entries (after set_shift_instance): production_date := the shift instance''s production_date, else app.production_date(timestamp, plant tz, production_day_start). Client value ignored. Never raises.';
revoke all on function app.set_row_production_date() from public, anon, authenticated;

-- Trigger names sort after *_set_shift_instance, so the instance is already resolved.
create trigger washer_cycles_set_shift_production_date before insert on public.washer_cycles
  for each row execute function app.set_row_production_date();
create trigger fge_set_shift_production_date before insert on public.finished_goods_entries
  for each row execute function app.set_row_production_date();

-- No backfill: both tables are empty in every environment (cloud verified 2026-11-02). Views fall back
-- to the shift instance or app.production_date() when the column is null.

-- ── 3. queue_items.loads_started ──────────────────────────────────────────
alter table public.queue_items
  add column loads_started int not null default 0
    constraint queue_items_loads_started_range check (loads_started between 0 and 100000);
comment on column public.queue_items.loads_started is
  'M2: loads started from this item by washer start-taps (start_washer_load +1, undo_washer_load −1). Remaining = loads_needed − loads_started. Written only by those RPCs.';

-- Loads the item needs before it is auto-completed by start-taps: ceil of the load equivalent for
-- 'load' and 'basket' units (through app.to_loads, the one conversion function); null for piece/pack
-- (approximate) or without a factor, so such items are completed by hand (set_queue_item_status).
create function app.queue_loads_needed(p_wash_group_id uuid, p_item_type_id uuid, p_qty numeric, p_unit app.qty_unit)
returns int language sql stable set search_path = '' as $$
  select case when p_unit in ('load', 'basket')
              then pg_catalog.ceil(app.to_loads(p_wash_group_id, p_item_type_id, p_qty, p_unit))::int end;
$$;
comment on function app.queue_loads_needed(uuid, uuid, numeric, app.qty_unit) is
  'M2: whole loads a queue item needs = ceil(app.to_loads(qty)) for load/basket units; null for piece/pack or a missing factor (never auto-completed). SECURITY INVOKER: caller''s RLS applies.';
revoke all on function app.queue_loads_needed(uuid, uuid, numeric, app.qty_unit) from public, anon;
grant execute on function app.queue_loads_needed(uuid, uuid, numeric, app.qty_unit) to authenticated, service_role;

-- ── 4. wash_groups.ships_next_morning ─────────────────────────────────────
alter table public.wash_groups add column ships_next_morning boolean not null default false;
comment on column public.wash_groups.ships_next_morning is
  'Owner 2026-11-02: daily-turnaround goods (mats, sheets, butcher coats) processed the same night and shipped on the 06:00 trucks. Drives the owner''s pace cards (G6). Owner/manager editable.';

-- ── 5. bump_queue_version: undo may reopen ────────────────────────────────
create or replace function app.bump_queue_version()
returns trigger language plpgsql set search_path = '' as $$
declare
  -- Security review L2: the reopen moves are tied to the data change that justifies them (a washer
  -- load given back), not to a session setting.
  v_undo boolean := new.loads_started < old.loads_started;
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
    elsif v_undo and (old.status, new.status) = ('done', 'in_progress') then
      new.completed_at := null;                -- undo of the tap that completed it
    elsif v_undo and (old.status, new.status) in (('in_progress', 'queued'), ('done', 'queued')) then
      new.started_at := null;                  -- undo of the only tap (that also completed it)
      new.completed_at := null;
    else
      raise exception 'INVALID_STATUS_TRANSITION' using detail = format('%s → %s', old.status, new.status);
    end if;
  end if;
  return new;
end;
$$;
comment on function app.bump_queue_version() is
  '§4.5 BEFORE UPDATE on queue_items: version+1, updated_at/updated_by, started_at/completed_at on transitions; raises INVALID_STATUS_TRANSITION for anything but queued→in_progress→done or queued/in_progress→cancelled. M2 (security review L2): in the same UPDATE that lowers loads_started (only undo_washer_load does), also done→in_progress (clears completed_at) and in_progress/done→queued (clears started_at and completed_at).';

-- ── 6. Views: exclude voided cycles; use the snapshotted production_date ──
-- Same columns, names and order as before (CREATE OR REPLACE); only filters/expressions change.
create or replace view public.washroom_by_shift with (security_invoker = true) as
select w.org_id,
       w.plant_id,
       w.area_id,
       w.shift_instance_id,
       coalesce(si.production_date, w.production_date, app.production_date(w.started_at, p.timezone, p.production_day_start)) as production_date,
       w.wash_group_id,
       sum(w.load_count)::int                                                              as loads_run,
       coalesce(sum(w.load_count * w.load_factor_used) filter (where not w.is_rewash), 0)::numeric as standard_loads,
       coalesce(bool_or(w.load_factor_used <> 1) filter (where not w.is_rewash), false)    as approximate,
       coalesce(sum(w.load_count) filter (where w.is_rewash), 0)::int                      as rewash_loads
  from public.washer_cycles w
  join public.plants p on p.id = w.plant_id
  left join public.shift_instances si on si.id = w.shift_instance_id
 where w.voided_at is null
 group by w.org_id, w.plant_id, w.area_id, w.shift_instance_id, 5, w.wash_group_id;
comment on view public.washroom_by_shift is
  '§4.6 Washroom per wash group per shift instance (wash_group_id null = unmapped formula); voided cycles excluded (M2). loads_run = sum(load_count) over ALL live cycles (rewash included, raw washer work); rewash_loads = sum(load_count) of rewash cycles (raw); standard_loads = sum(load_count × load_factor_used) over NON-rewash cycles only; approximate = some non-rewash load had a factor ≠ 1. production_date = the instance''s production day, else the row''s snapshotted production_date (off-shift).';

create or replace view public.finished_by_shift with (security_invoker = true) as
select f.org_id,
       f.plant_id,
       f.area_id,
       f.shift_instance_id,
       coalesce(si.production_date, f.production_date, app.production_date(f.occurred_at, p.timezone, p.production_day_start)) as production_date,
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
  '§4.6 Non-voided finished goods per ITEM and line per shift instance (wash_group_id = the item''s group when entered, snapshotted); loads_approx = to_loads(pieces, ''piece'') (approximate, null without pieces_per_load). production_date = the instance''s production day, else the row''s snapshotted production_date (off-shift).';

create or replace view public.daily_reconciliation with (security_invoker = true) as
with washed as (
  select w.org_id, w.plant_id,
         coalesce(si.production_date, w.production_date, app.production_date(w.started_at, p.timezone, p.production_day_start)) as production_date,
         w.wash_group_id,
         sum(w.load_count)::numeric                                                       as loads_run,
         coalesce(sum(w.load_count * w.load_factor_used) filter (where not w.is_rewash), 0)::numeric as standard_loads,
         coalesce(sum(w.load_count) filter (where w.is_rewash), 0)::numeric               as rewash_loads
    from public.washer_cycles w
    join public.plants p on p.id = w.plant_id
    left join public.shift_instances si on si.id = w.shift_instance_id
   where w.wash_group_id is not null and w.voided_at is null
   group by 1, 2, 3, 4
), finished_items as (
  select f.org_id, f.plant_id,
         coalesce(si.production_date, f.production_date, app.production_date(f.occurred_at, p.timezone, p.production_day_start)) as production_date,
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
         coalesce(w.rewash_loads, 0)                    as rewash_loads,
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
       true                                                    as approximate,
       k.rewash_loads
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
  '§4.6/G1 Washroom vs finishing per WASH GROUP per PRODUCTION DAY (owner 2026-11-01). Voided cycles and entries excluded. loads_run = sum(load_count) over ALL live cycles (rewash included); rewash_loads = sum(load_count) of rewash cycles; standard_loads = sum(load_count × load_factor_used) over NON-rewash cycles only. loads_finished_approx = Σ over the group''s items of to_loads(pieces, ''piece''); it and clean_backlog_loads_approx are null when finished_incomplete (see pieces_without_conversion; loads_finished_partial_approx = sum over the items that convert). Off-shift rows use their snapshotted production_date. approximate is always true. estimate_error_pct stays null until the owner approves its formula.';

-- queue_board: same columns as 20261102005126, plus progress at the end.
create or replace view public.queue_board with (security_invoker = true) as
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
       q.created_at,
       q.assigned_machine_id,                          -- null = next free washer
       m.name                                          as assigned_machine_name,
       q.is_rewash,                                    -- sent back by finishing
       q.loads_started,                                -- M2: washer start-taps on this item
       n.loads_needed,                                 -- null = completed by hand (piece/pack or no factor)
       greatest(n.loads_needed - q.loads_started, 0)   as loads_remaining
  from public.queue_items q
  join public.wash_groups g on g.id = q.wash_group_id
  left join public.item_types i on i.id = q.item_type_id
  left join public.machines m on m.id = q.assigned_machine_id
  cross join lateral (select app.queue_loads_needed(q.wash_group_id, q.item_type_id, q.qty, q.unit) as loads_needed) n
 where q.status in ('queued', 'in_progress');
comment on view public.queue_board is
  '§4.6 Open queue (queued/in_progress) per area: wash group names in all languages, plus the optional item; qty_loads via app.to_loads (piece/pack approximate, null without a factor); assigned_machine_id/name (null = next free washer); is_rewash; loads_started / loads_needed / loads_remaining (M2 start-taps; loads_needed null = completed by hand). Order by is_rush desc, position asc.';

revoke all on public.washroom_by_shift, public.finished_by_shift, public.daily_reconciliation, public.queue_board from anon, authenticated;
grant select on public.washroom_by_shift, public.finished_by_shift, public.daily_reconciliation, public.queue_board to authenticated;
