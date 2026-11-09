-- Queue "loads left" is unknown, not 0, when the loads needed are unknown (review 2026-11-09, item 2 follow-up).
-- greatest(x, 0) IGNORES a null x in Postgres, so greatest(loads_needed - loads_started, 0) gave 0 for an item
-- whose loads_needed is null (piece/pack quantities, or a basket/bin quantity whose group has no factor yet,
-- e.g. AA Kitchen towels in bins). The app then showed "0 loads left" for work that may be large.
-- Now: loads_remaining is null whenever loads_needed is null; otherwise greatest(needed - started, 0) as before.
-- * public.queue_board.loads_remaining (and so get_queue.loads_remaining, which reads the view);
-- * public.get_washroom_board.next_loads_remaining (same expression, computed inline).
-- get_wash_group_pace sums the view's loads_remaining and counts the null ones separately
-- (queue_items_without_load_count), so its totals are unchanged (a null added 0 before, and is skipped now).
-- No signature or column changes.

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
       n.loads_needed,                                 -- null = unknown (piece/pack or no factor): completed by hand
       case when n.loads_needed is not null
            then greatest(n.loads_needed - q.loads_started, 0) end as loads_remaining   -- null when unknown
  from public.queue_items q
  join public.wash_groups g on g.id = q.wash_group_id
  left join public.item_types i on i.id = q.item_type_id
  left join public.machines m on m.id = q.assigned_machine_id
  cross join lateral (select app.queue_loads_needed(q.wash_group_id, q.item_type_id, q.qty, q.unit) as loads_needed) n
 where q.status in ('queued', 'in_progress');
comment on view public.queue_board is
  '§4.6 Open queue (queued/in_progress) per area: wash group names in all languages, plus the optional item; qty_loads via app.to_loads (piece/pack approximate, null without a factor); assigned_machine_id/name (null = next free washer); is_rewash; loads_started / loads_needed / loads_remaining (M2 start-taps; loads_needed null = unknown, completed by hand; loads_remaining null whenever loads_needed is null, since 2026-11-09). Order by is_rush desc, position asc.';
revoke all on public.queue_board from anon, authenticated;
grant select on public.queue_board to authenticated;

-- get_washroom_board: only the next_loads_remaining expression changes.
create or replace function public.get_washroom_board(p_area_id uuid)
 RETURNS TABLE(machine_id uuid, machine_name text, load_factor numeric, status text, cycle_id uuid, wash_group_id uuid, wash_group_name text, wash_group_name_i18n jsonb, wash_group_color_hex text, is_rewash boolean, wash_formula_id uuid, formula_external_no text, formula_name text, cycle_minutes integer, started_at timestamp with time zone, expected_end_at timestamp with time zone, minutes_since_start integer, minutes_ready integer, queue_item_id uuid, next_queue_item_id uuid, next_is_assigned boolean, next_wash_group_id uuid, next_wash_group_name text, next_wash_group_name_i18n jsonb, next_wash_group_color_hex text, next_item_type_id uuid, next_item_name text, next_item_name_i18n jsonb, next_qty numeric, next_unit app.qty_unit, next_is_rush boolean, next_is_rewash boolean, next_loads_remaining integer, next_version integer, server_time timestamp with time zone, is_down boolean, down_reason text, down_since timestamp with time zone, down_reason_code text, down_reason_label_i18n jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_area   record;
  v_now    timestamptz := pg_catalog.now();
  v_reason boolean;
begin
  select a.id, a.plant_id into v_area from public.areas a where a.id = p_area_id;
  if v_area.id is null
     or not (app.has_role(v_area.plant_id, '{owner,manager,lead,viewer}')
             or (app.is_display(v_area.plant_id) and (app.my_device()).area_id = v_area.id)) then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_washroom_board requires a role on the area''s plant, or a display of this area';
  end if;
  v_reason := app.has_role(v_area.plant_id, '{owner,manager}');   -- L6: free-text reasons for owner/manager only

  return query
  select m.id, m.name, m.load_factor,
         case when c.id is null then 'idle'
              when f.cycle_minutes is null then 'unknown'
              when v_now < c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes) then 'running'
              else 'ready' end,
         c.id, c.wash_group_id, g.name, g.name_i18n, g.color_hex, c.is_rewash,
         c.wash_formula_id, f.external_no, f.name, f.cycle_minutes,
         c.started_at,
         c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes),
         (extract(epoch from (v_now - c.started_at)) / 60)::int,
         case when f.cycle_minutes is not null and v_now >= c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes)
              then (extract(epoch from (v_now - (c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes)))) / 60)::int end,
         c.queue_item_id,
         n.id, n.assigned_machine_id is not null, n.wash_group_id, ng.name, ng.name_i18n, ng.color_hex,
         n.item_type_id, ni.name, ni.name_i18n, n.qty, n.unit, n.is_rush, n.is_rewash,
         case when app.queue_loads_needed(n.wash_group_id, n.item_type_id, n.qty, n.unit) is not null
              then greatest(app.queue_loads_needed(n.wash_group_id, n.item_type_id, n.qty, n.unit) - n.loads_started, 0) end,
         n.version,
         v_now,
         coalesce(s.status = 'down', false),
         case when s.status = 'down' and v_reason then s.reason end,
         case when s.status = 'down' then s.occurred_at end,
         case when s.status = 'down' and v_reason then s.reason_code end,
         case when s.status = 'down' and v_reason then s.label_i18n end
    from public.machines m
    left join lateral (
      select e.status, e.reason, e.reason_code, e.occurred_at, r.label_i18n from public.machine_status_events e
        left join public.machine_down_reasons r on r.plant_id = e.plant_id and r.code = e.reason_code
       where e.machine_id = m.id and e.plant_id = m.plant_id
       order by e.occurred_at desc, e.seq desc
       limit 1) s on true
    left join lateral (
      select w.* from public.washer_cycles w
       where w.machine_id = m.id and w.plant_id = m.plant_id and w.voided_at is null
       order by w.started_at desc, w.id desc
       limit 1) c on true
    left join public.wash_groups g on g.id = c.wash_group_id
    left join public.wash_formulas f on f.id = c.wash_formula_id
    left join lateral (
      select q.* from public.queue_items q
       where q.area_id = m.area_id and q.plant_id = m.plant_id
         and q.status in ('queued', 'in_progress')
         and (q.assigned_machine_id = m.id or q.assigned_machine_id is null)
         and s.status is distinct from 'down'            -- a down washer gets no NEXT
       order by (q.assigned_machine_id is not null) desc, q.is_rush desc, q.position, q.id
       limit 1) n on true
    left join public.wash_groups ng on ng.id = n.wash_group_id
    left join public.item_types ni on ni.id = n.item_type_id
   where m.area_id = v_area.id and m.plant_id = v_area.plant_id and m.kind = 'washer' and m.active
   order by m.name, m.id;
end;
$function$;
