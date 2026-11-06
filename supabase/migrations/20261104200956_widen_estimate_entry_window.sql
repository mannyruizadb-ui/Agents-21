-- record_soil_estimate: widen the p_entered_at window to [now − 6 h, now + 1 min] (coordinator,
-- 2026-11-04). An estimate is a snapshot of the dirty work at that time; current_soil_estimates orders
-- by entered_at, so a late one never replaces a newer one, and a phone that was offline for a few
-- hours should not lose it. Washer taps keep their 30-minute window (start_washer_load).

CREATE OR REPLACE FUNCTION public.record_soil_estimate(p_wash_group_id uuid, p_qty numeric, p_unit app.qty_unit, p_client_id uuid, p_staff_session_id uuid, p_note text DEFAULT NULL::text, p_entered_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS public.soil_estimates
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_g     record;
  v_row   public.soil_estimates;
  v_note  text;
  v_staff uuid;
  v_now   timestamptz := pg_catalog.now();
  v_ts    timestamptz;
begin
  select g.id, g.org_id, g.plant_id, g.active, g.allow_basket_estimates, g.allow_bin_estimates into v_g
    from public.wash_groups g where g.id = p_wash_group_id;
  if v_g.id is null or not app.has_role(v_g.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'record_soil_estimate requires owner or manager on the wash group''s plant';
  end if;
  if p_client_id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: required';
  end if;
  select e.* into v_row from public.soil_estimates e where e.client_id = p_client_id;
  if v_row.id is not null then
    if v_row.plant_id = v_g.plant_id then
      return v_row;
    end if;
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';
  end if;
  -- Offline estimates keep their real time; checked after idempotency, so a late retry of a saved
  -- estimate still returns it.
  v_ts := coalesce(p_entered_at, v_now);
  if v_ts < v_now - interval '6 hours' or v_ts > v_now + interval '1 minute' then
    raise exception 'OUT_OF_RANGE_TIMESTAMP' using detail = 'p_entered_at: must be within the last 6 hours (up to 1 minute ahead)';
  end if;
  if not v_g.active then
    raise exception 'VALIDATION_FAILED' using detail = 'wash_group_id: the wash group is inactive';
  end if;
  perform app.check_qty(p_qty, 0, 10000, 'qty');
  if p_unit is null or p_unit not in ('load', 'basket', 'bin') then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: load, basket or bin';
  end if;
  if p_unit = 'basket' and not v_g.allow_basket_estimates then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: basket estimates are not allowed for this wash group';
  end if;
  if p_unit = 'bin' and not v_g.allow_bin_estimates then
    raise exception 'VALIDATION_FAILED' using detail = 'unit: bin estimates are not allowed for this wash group';
  end if;
  v_note := app.clean_note(p_note, 280, 'note');
  v_staff := app.use_staff_session(p_staff_session_id, v_g.plant_id);

  insert into public.soil_estimates as e (org_id, plant_id, wash_group_id, qty, unit, note, entered_by, staff_id, client_id, entered_at)
  values (v_g.org_id, v_g.plant_id, v_g.id, p_qty, p_unit, v_note, (select auth.uid()), v_staff, p_client_id, v_ts)
  on conflict (client_id) do nothing
  returning e.* into v_row;
  if v_row.id is null then
    raise exception 'VALIDATION_FAILED' using detail = 'p_client_id: already used';   -- concurrent retry; the client refetches
  end if;
  return v_row;
end;
$function$;
comment on function public.record_soil_estimate(uuid, numeric, app.qty_unit, uuid, uuid, text, timestamptz) is
  'B1 RPC (owner/manager + staff session, A8): appends a soil estimate for a wash group (never updates; 0 = cleared). qty 0–10,000 (2 decimals; e.g. 2.75 bins) in load, or basket / bin when the group allows it; note ≤ 280; p_entered_at = the device time of an offline entry (default now; within [now − 6 h, now + 1 min], else OUT_OF_RANGE_TIMESTAMP). Idempotent on p_client_id, checked before the time window and the session (returns the existing row, even after the single-use session is spent). Returns the soil_estimates row. Errors: NOT_AUTHORIZED, VALIDATION_FAILED, OUT_OF_RANGE_TIMESTAMP, STAFF_SESSION_REQUIRED.';
