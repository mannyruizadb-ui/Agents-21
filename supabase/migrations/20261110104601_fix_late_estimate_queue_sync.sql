-- Audit 2026-11-10: a late offline estimate double-counted loads in the washroom queue.
--
-- An estimate is "what is still dirty out there" at its entered_at (the device time; an offline estimate
-- can arrive up to 6 h late). app.sync_estimate_queue_item (20261109193413) set an in-progress item's qty to
-- loads_started + the estimate, counting ALL starts on the item, including starts AFTER entered_at, which
-- already washed part of the estimated pile. Example: estimate 3 loads entered at T, starts at T+5 and
-- T+10, the estimate syncs at T+15 → qty 2 + 3 = 5, 3 loads left (should be 1).
--
-- Now (owner 2026-11-10, one "loads left" rule: the estimate minus the group's starts since the estimate
-- was entered, EACH START = 1 LOAD; get_wash_group_pace's started_at > entered_at rule):
-- * app.estimate_starts_since(plant, group, since): the number of live (non-voided), non-rewash washer
--   cycles of the group with started_at > since, on any queue item or off-queue. The one counter, also
--   used by current_soil_estimates.loads_left and get_wash_group_pace (20261110105124).
-- * With a conversion, the estimate's loads still to wash = greatest(estimate loads − those starts, 0):
--     no open item  → a new item with that qty in 'load' (nothing opened at 0);
--     not started   → qty := that in 'load' (cancelled at 0);
--     in progress   → qty := loads_started + that, in 'load'. The item's own starts after entered_at are
--                     in both terms, so starts made before the estimate stay outside it and later ones
--                     are not counted twice. The audit case: estimate 3 loads at T, starts at T+5 / T+10
--                     on the item, sync at T+15 → qty 2 + 1 = 3, 1 load left (was 5 and 3 left).
--   When there are no such starts the item takes the estimate's own qty / unit as before (e.g. baskets).
--   So at sync time the item's loads_remaining = greatest(ceil(round(estimate loads, 2)) − starts since, 0)
--   = current_soil_estimates.loads_left.
-- * Without a conversion nothing is subtracted (never a guessed conversion): the estimate's own qty / unit.
-- * Rounding (audit 2026-11-10, as app.queue_loads_needed since 20261110104559): a load qty is stored as
--   round(x, 2) (was ceil(x × 100) / 100, a round-UP that made ceil() need one load more than the app's
--   ceil(round(x, 2)), e.g. 2.001).
-- Everything else is identical to 20261109193413 (internal, owner/manager callers via record_soil_estimate,
-- area queue lock, only the group's current estimate, our own groups only, unchanged values write nothing,
-- qty 0 handling). Known limit: a start of the group made AFTER the sync on another item or off-queue does
-- not change the open estimate item (only its next re-estimate does); current_soil_estimates.loads_left
-- counts it at once.

create function app.estimate_starts_since(p_plant_id uuid, p_wash_group_id uuid, p_since timestamptz)
returns int language plpgsql stable security definer set search_path = '' as $$
begin
  -- Definer (washer_cycles RLS shows managers only the current shift), so it must check the caller: a
  -- signed-in caller needs a reading role on the plant (the soil_estimates readers), else null.
  if (select auth.uid()) is not null
     and not (app.has_role(p_plant_id, '{owner,manager,lead,viewer}') or app.is_display(p_plant_id)) then
    return null;
  end if;
  return (select count(*)::int from public.washer_cycles c
           where c.plant_id = p_plant_id and c.wash_group_id = p_wash_group_id
             and c.voided_at is null and not c.is_rewash and c.started_at > p_since);
end;
$$;
comment on function app.estimate_starts_since(uuid, uuid, timestamptz) is
  'Owner 2026-11-10 (one "loads left" rule, each start = 1 load): number of live (non-voided), non-rewash washer cycles of the wash group with started_at > p_since (any queue item or off-queue). Definer; a signed-in caller without owner/manager/lead/viewer or a display on the plant gets null. Used by app.sync_estimate_queue_item, current_soil_estimates.loads_left and get_wash_group_pace.';
revoke all on function app.estimate_starts_since(uuid, uuid, timestamptz) from public, anon;
grant execute on function app.estimate_starts_since(uuid, uuid, timestamptz) to authenticated, service_role;

create or replace function app.sync_estimate_queue_item(p_estimate_id uuid)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare
  v_e     public.soil_estimates;
  v_g     record;
  v_area  uuid;
  v_areas int;
  v_q     public.queue_items;
  v_loads numeric;
  v_after int := 0;
  v_qty   numeric;
  v_unit  app.qty_unit;
  v_need  int;
begin
  select e.* into v_e from public.soil_estimates e where e.id = p_estimate_id;
  if v_e.id is null then
    return null;
  end if;
  select g.id, g.active, g.customer_id into v_g
    from public.wash_groups g where g.id = v_e.wash_group_id and g.plant_id = v_e.plant_id;
  if v_g.id is null or not v_g.active or v_g.customer_id is not null then
    return null;                                   -- customer (AA) groups keep their delivery flow
  end if;
  select count(*), min(a.id::text)::uuid into v_areas, v_area
    from public.areas a where a.plant_id = v_e.plant_id and a.kind = 'washroom' and a.active;
  if v_areas <> 1 then
    return null;
  end if;

  -- Serialize with every queue writer of the area (positions, the one-open-item rule, start taps).
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('queue:' || v_area::text, 0));

  -- Only the group's current estimate (current_soil_estimates order) drives the queue.
  if exists (select 1 from public.soil_estimates e
              where e.plant_id = v_e.plant_id and e.wash_group_id = v_e.wash_group_id and e.id <> v_e.id
                and (e.entered_at > v_e.entered_at or (e.entered_at = v_e.entered_at and e.id > v_e.id))) then
    return null;
  end if;

  select q.* into v_q from public.queue_items q
   where q.area_id = v_area and q.plant_id = v_e.plant_id and q.wash_group_id = v_e.wash_group_id
     and q.from_estimate and q.status in ('queued', 'in_progress')
   for update;

  -- What the estimate still covers after the group's starts since it was entered (null = no factor).
  if v_e.qty > 0 then
    v_after := app.estimate_starts_since(v_e.plant_id, v_e.wash_group_id, v_e.entered_at);
    v_loads := app.to_loads(v_e.wash_group_id, null, v_e.qty, v_e.unit);
    if v_loads is not null then
      v_loads := greatest(v_loads - v_after, 0);
    end if;
  end if;

  if v_q.id is null or v_q.loads_started = 0 then
    if v_e.qty > 0 and v_after > 0 and v_loads is not null then
      v_qty := pg_catalog.round(v_loads, 2);       -- starts since the estimate washed part of it
      v_unit := 'load';
    else
      v_qty := v_e.qty;                            -- as entered (no starts since, or no factor)
      v_unit := v_e.unit;
    end if;
    if v_q.id is null then
      if v_qty <= 0 then
        return null;
      end if;
      insert into public.queue_items as q (org_id, plant_id, area_id, wash_group_id, item_type_id, qty, unit, position,
                                           is_rush, note, created_by, client_id, assigned_machine_id, is_rewash, from_estimate)
      values (v_e.org_id, v_e.plant_id, v_area, v_e.wash_group_id, null, least(v_qty, 100000), v_unit,
              app.queue_edge_position(v_area, false, false, null),
              false, null, v_e.entered_by, gen_random_uuid(), null, false, true)
      returning q.* into v_q;
      return v_q.id;
    end if;
    if v_qty <= 0 then
      update public.queue_items q set status = 'cancelled' where q.id = v_q.id;
      return v_q.id;
    end if;
  elsif v_e.qty <= 0 then
    v_qty := v_q.loads_started;
    v_unit := 'load';
  elsif v_loads is null then
    v_qty := v_e.qty;                              -- no factor: never add baskets to loads
    v_unit := v_e.unit;
  else
    v_qty := least(pg_catalog.round(v_q.loads_started + v_loads, 2), 100000);
    v_unit := 'load';
  end if;

  if v_q.qty is distinct from v_qty or v_q.unit is distinct from v_unit then
    update public.queue_items q set qty = v_qty, unit = v_unit where q.id = v_q.id returning q.* into v_q;
  end if;
  v_need := app.queue_loads_needed(v_q.wash_group_id, v_q.item_type_id, v_q.qty, v_q.unit);
  if v_q.status = 'in_progress' and v_need is not null and v_q.loads_started >= v_need then
    update public.queue_items q set status = 'done' where q.id = v_q.id;
  end if;
  return v_q.id;
end;
$$;
comment on function app.sync_estimate_queue_item(uuid) is
  'Owner 2026-11-09 (estimates fill the queue); audit + owner 2026-11-10 (late offline estimates, one "loads left" rule): keeps the ONE open from_estimate queue item of the estimate''s wash group in the plant''s only active washroom area in step with the group''s CURRENT estimate (latest entered_at, then id). Our own active groups only (customer_id null). Under the area queue lock. Still to wash = greatest(estimate loads − app.estimate_starts_since(group, entered_at), 0) (each live non-rewash start since the estimate = 1 load). No item → insert at the bottom of the normal items (created_by = entered_by; nothing at 0). Not started → qty/unit in place (position, rush, washer, note kept); 0 → cancelled. Both use the estimate''s own qty/unit when there were no starts since (or no factor), else that remainder in ''load''. In progress → qty = loads_started + the remainder in ''load'' (estimate qty/unit when the unit has no factor); estimate 0 → qty = loads_started → done. Load qty = round(x, 2); done when loads_started ≥ ceil(round(qty, 2)); so loads_remaining = current_soil_estimates.loads_left at sync time. Unchanged values write nothing. Returns the queue item id (null = nothing to do). Internal: the caller checks the role.';
revoke all on function app.sync_estimate_queue_item(uuid) from public, anon, authenticated;
