-- Owner 2026-11-05: "Managers: current shift totals only, NOT the previous shift." Locked server side.
--
-- 1. get_shift_report: the owner reads any shift; manager / lead / viewer only the shift instance that
--    is running now (not skipped, starts_at ≤ now < ends_at). Anything else → NOT_AUTHORIZED.
-- 2. The history views daily_reconciliation, washroom_by_shift and finished_by_shift lose their client
--    grant (no screen reads them: checked src/). The owner gets the same data through the owner-only
--    RPCs get_day_report / get_wash_group_pace / get_shift_report, which read the views as definer.
--    queue_board and current_soil_estimates (the manager screens' views) are unchanged.
-- 3. The raw rows behind the totals: washer_cycles and finished_goods_entries are readable by the
--    owner in full, and by manager / lead / viewer only for the CURRENT shift instance of the row's
--    area (off-shift rows and past shifts are owner-only). No screen reads these tables directly
--    (board and reports use definer RPCs). soil_estimates is unchanged: an estimate is a snapshot,
--    not a shift total, and current_soil_estimates needs the latest one whenever it was entered.

revoke all on public.daily_reconciliation, public.washroom_by_shift, public.finished_by_shift from anon, authenticated;
comment on view public.daily_reconciliation is
  '§4.6/G1 washroom vs finishing per wash group per production day. Owner-only since 2026-11-05: no client grant; read through get_day_report (owner).';
comment on view public.washroom_by_shift is
  '§4.6 loads per wash group per shift instance. Owner-only since 2026-11-05: no client grant; read through get_shift_report / get_wash_group_pace.';
comment on view public.finished_by_shift is
  '§4.6 finished goods per item and line per shift instance. Owner-only since 2026-11-05: no client grant; read through get_shift_report.';

drop policy washer_cycles_select on public.washer_cycles;
create policy washer_cycles_select on public.washer_cycles for select to authenticated
  using ((select app.has_role(plant_id, '{owner}'))
         or ((select app.has_role(plant_id, '{manager,lead,viewer}'))
             and exists (select 1 from public.shift_instances si
                          where si.id = washer_cycles.shift_instance_id and si.area_id = washer_cycles.area_id and si.skipped_at is null
                            and si.starts_at <= now() and si.ends_at > now())));
drop policy fge_select on public.finished_goods_entries;
create policy fge_select on public.finished_goods_entries for select to authenticated
  using ((select app.has_role(plant_id, '{owner}'))
         or ((select app.has_role(plant_id, '{manager,lead,viewer}'))
             and exists (select 1 from public.shift_instances si
                          where si.id = finished_goods_entries.shift_instance_id and si.area_id = finished_goods_entries.area_id and si.skipped_at is null
                            and si.starts_at <= now() and si.ends_at > now())));

CREATE OR REPLACE FUNCTION public.get_shift_report(p_shift_instance_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_si record;
begin
  select si.id, si.plant_id, si.area_id, si.shift_id, si.business_date, si.production_date, si.starts_at, si.ends_at,
         si.skipped_at, s.name, a.name as area_name, a.kind as area_kind
    into v_si
    from public.shift_instances si
    join public.shifts s on s.id = si.shift_id
    join public.areas a on a.id = si.area_id
   where si.id = p_shift_instance_id;
  if v_si.id is null or not app.has_role(v_si.plant_id, '{owner,manager,lead,viewer}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_shift_report requires owner, manager, lead or viewer on the shift''s plant';
  end if;
  -- Owner 2026-11-05: only the owner sees past (or future) shifts; everyone else sees the shift that
  -- is running now in that area. Same NOT_AUTHORIZED, so nothing distinguishes the cases.
  if not app.has_role(v_si.plant_id, '{owner}')
     and not (v_si.skipped_at is null and v_si.starts_at <= pg_catalog.now() and v_si.ends_at > pg_catalog.now()) then
    raise exception 'NOT_AUTHORIZED' using detail = 'get_shift_report: only the owner sees shifts other than the current one';
  end if;

  return jsonb_build_object(
    'shift', jsonb_build_object(
      'id', v_si.id, 'area_id', v_si.area_id, 'area_name', v_si.area_name, 'area_kind', v_si.area_kind,
      'shift_id', v_si.shift_id, 'name', v_si.name, 'business_date', v_si.business_date,
      'production_date', v_si.production_date, 'starts_at', v_si.starts_at, 'ends_at', v_si.ends_at,
      'skipped', v_si.skipped_at is not null),
    'washroom', coalesce((
      select jsonb_agg(jsonb_build_object(
               'wash_group_id', w.wash_group_id, 'wash_group_name', g.name, 'wash_group_name_i18n', g.name_i18n,
               'loads_run', w.loads_run, 'standard_loads', w.standard_loads, 'rewash_loads', w.rewash_loads,
               'approximate', w.approximate)
             order by g.sort_order nulls last, g.name)
        from public.washroom_by_shift w
        left join public.wash_groups g on g.id = w.wash_group_id
       where w.shift_instance_id = v_si.id), '[]'::jsonb),
    'finishing', coalesce((
      select jsonb_agg(jsonb_build_object(
               'item_type_id', x.item_type_id, 'item_name', i.name, 'item_name_i18n', i.name_i18n,
               'wash_group_id', x.wash_group_id, 'packs', x.packs, 'loose_pieces', x.loose_pieces, 'pieces', x.pieces,
               'loads_approx', app.to_loads(null, x.item_type_id, x.pieces::numeric, 'piece'),
               'has_conversion', app.to_loads(null, x.item_type_id, x.pieces::numeric, 'piece') is not null,
               'by_line', x.by_line)
             order by i.sort_order, i.name)
        from (select f.item_type_id, f.wash_group_id,
                     sum(f.packs)::int as packs, sum(f.loose_pieces)::int as loose_pieces, sum(f.pieces)::int as pieces,
                     -- Line totals. Privacy note (review M1): a line run by one person makes its total that
                     -- person's output; shown because lines are equipment, but revisit with HR/legal.
                     jsonb_agg(jsonb_build_object('station_id', f.station_id, 'station_name', st.name,
                                                  'packs', f.packs, 'loose_pieces', f.loose_pieces, 'pieces', f.pieces)
                               order by st.name nulls first) as by_line
                from public.finished_by_shift f
                left join public.stations st on st.id = f.station_id
               where f.shift_instance_id = v_si.id
               group by f.item_type_id, f.wash_group_id) x
        join public.item_types i on i.id = x.item_type_id), '[]'::jsonb),
    'totals', jsonb_build_object(
      'loads_run',      coalesce((select sum(w.loads_run) from public.washroom_by_shift w where w.shift_instance_id = v_si.id), 0),
      'standard_loads', coalesce((select sum(w.standard_loads) from public.washroom_by_shift w where w.shift_instance_id = v_si.id), 0),
      'rewash_loads',   coalesce((select sum(w.rewash_loads) from public.washroom_by_shift w where w.shift_instance_id = v_si.id), 0),
      'pieces',         coalesce((select sum(f.pieces) from public.finished_by_shift f where f.shift_instance_id = v_si.id), 0)),
    -- Queue at shift end: completed in the shift window; remaining = open at its end (created before
    -- the end, still open now or completed after it). Cancelled items are not counted.
    'queue', jsonb_build_object(
      'completed', (select count(*) from public.queue_items q
                     where q.area_id = v_si.area_id and q.status = 'done'
                       and q.completed_at >= v_si.starts_at and q.completed_at < v_si.ends_at),
      'remaining', (select count(*) from public.queue_items q
                     where q.area_id = v_si.area_id and q.created_at < v_si.ends_at
                       and (q.status in ('queued', 'in_progress') or (q.status = 'done' and q.completed_at >= v_si.ends_at)))),
    -- Security review M1 (privacy): crew_count / labor_hours are NOT reported until HR/legal review.
    -- With a crew of 1 they are one person's hours next to that shift's output (per-worker data, §6.2 #11).
    'server_time', pg_catalog.now());
end;
$function$;
comment on function public.get_shift_report(uuid) is
  'G1 shift report (owner: any shift; manager/lead/viewer: only the area''s CURRENT shift instance, owner 2026-11-05; definer, role check first, plant-filtered). jsonb: {shift{id, area_id, area_name, area_kind, shift_id, name, business_date, production_date, starts_at, ends_at, skipped}, washroom[{wash_group_id, wash_group_name, wash_group_name_i18n, loads_run, standard_loads, rewash_loads, approximate}], finishing[{item_type_id, item_name, item_name_i18n, wash_group_id, packs, loose_pieces, pieces, loads_approx, has_conversion, by_line[{station_id, station_name, packs, loose_pieces, pieces}]}], totals{loads_run, standard_loads, rewash_loads, pieces}, queue{completed, remaining}, server_time}. No crew hours (privacy, pending HR/legal review). Voided rows excluded; off-shift rows are in the day report only. No per-person data. Errors: NOT_AUTHORIZED.';
