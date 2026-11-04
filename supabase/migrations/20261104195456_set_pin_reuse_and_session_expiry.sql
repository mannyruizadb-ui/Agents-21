-- Owner decision 2026-11-04: a confirmed PIN is good for 10 minutes on a phone ("for now").
--
-- 1. start_staff_session also returns expires_at (when the session stops being reusable), so the
--    client can show "PIN valid until …" and ask again in time. Backward compatible: the result type
--    gains a LAST attribute; staff_session_id / error / locked_until are unchanged.
-- 2. DATA: plants.staff_pin_reuse_minutes = 10 for the ADB plant (org 'americas-dust-busters',
--    plant 'Miami'). Only where it is still the default 0, so an owner edit is never overwritten.
--    seed.sql sets the same value for fresh databases. With a reuse window the session is not
--    consumed by an entry (app.use_staff_session) and stays valid until expires_at.

alter type public.staff_session_result add attribute expires_at timestamptz;
comment on type public.staff_session_result is
  'start_staff_session result: staff_session_id (success), error (PIN_INVALID | STAFF_LOCKED), locked_until (when locked), expires_at (success: when the session ends; owner 2026-11-04).';

CREATE OR REPLACE FUNCTION public.start_staff_session(p_staff_id uuid, p_pin text)
 RETURNS public.staff_session_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_staff   record;
  v_reuse   int;
  v_now     timestamptz := pg_catalog.now();
  v_result  public.staff_session_result;
  v_expires timestamptz;
begin
  if p_staff_id is null or p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception 'VALIDATION_FAILED' using detail = 'p_staff_id required; p_pin exactly 4 digits';
  end if;
  select s.id, s.org_id, s.plant_id, s.active, s.pin_hash, s.failed_pin_attempts, s.locked_until
    into v_staff
    from public.entry_staff s
   where s.id = p_staff_id
     for update;
  if not found or (select auth.uid()) is null
     or not app.has_role(v_staff.plant_id, '{owner,manager,lead}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'start_staff_session requires owner, manager or lead on the staff''s plant';
  end if;
  if not v_staff.active then
    raise exception 'VALIDATION_FAILED' using detail = 'staff: inactive';
  end if;
  if v_staff.pin_hash is null then
    raise exception 'VALIDATION_FAILED' using detail = 'staff: PIN not set';
  end if;

  if v_staff.locked_until is not null and v_staff.locked_until > v_now then
    v_result.error := 'STAFF_LOCKED';
    v_result.locked_until := v_staff.locked_until;
    return v_result;
  end if;

  if extensions.crypt(p_pin, v_staff.pin_hash) = v_staff.pin_hash then
    update public.entry_staff s
       set failed_pin_attempts = 0, locked_until = null
     where s.id = p_staff_id;
    select p.staff_pin_reuse_minutes into v_reuse from public.plants p where p.id = v_staff.plant_id;
    v_expires := v_now + case when coalesce(v_reuse, 0) = 0 then interval '2 minutes'
                              else pg_catalog.make_interval(mins => v_reuse) end;
    insert into public.staff_sessions as ss (org_id, plant_id, staff_id, auth_user_id, confirmed_at, expires_at)
    values (v_staff.org_id, v_staff.plant_id, p_staff_id, (select auth.uid()), v_now, v_expires)
    returning ss.id into v_result.staff_session_id;
    v_result.expires_at := v_expires;
    return v_result;
  end if;

  -- Wrong PIN: count it; the 5th consecutive failure locks the person for 5 minutes.
  if v_staff.failed_pin_attempts + 1 >= 5 then
    update public.entry_staff s
       set failed_pin_attempts = 0, locked_until = v_now + interval '5 minutes'
     where s.id = p_staff_id;
    v_result.error := 'STAFF_LOCKED';
    v_result.locked_until := v_now + interval '5 minutes';
  else
    update public.entry_staff s
       set failed_pin_attempts = s.failed_pin_attempts + 1
     where s.id = p_staff_id;
    v_result.error := 'PIN_INVALID';
  end if;
  return v_result;
end;
$function$;
comment on function public.start_staff_session(uuid, text) is
  'A8/D4 RPC (owner/manager/lead): confirm name + PIN. Returns (staff_session_id, error, locked_until, expires_at): success → session valid for the plant''s staff_pin_reuse_minutes (2 min, single use, when 0) and expires_at = when it ends; wrong PIN → error PIN_INVALID (counter persists); 5th failure or locked → STAFF_LOCKED + locked_until. Raises NOT_AUTHORIZED / VALIDATION_FAILED for bad caller, inactive staff, PIN not set or bad arguments.';

update public.plants p
   set staff_pin_reuse_minutes = 10
  from public.organizations o
 where o.id = p.org_id and o.slug = 'americas-dust-busters' and p.name = 'Miami'
   and p.staff_pin_reuse_minutes = 0;
