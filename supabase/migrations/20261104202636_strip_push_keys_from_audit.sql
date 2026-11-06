-- Security review 2026-11-04, H1 (BLOCK): app.audit() copied push_subscriptions.endpoint, p256dh and
-- auth into audit_log, which owners and managers can read. They are now stripped from before and
-- after; only endpoint_host (e.g. fcm.googleapis.com) is kept. A rebind to another org also drops the
-- previous org's ids from "before". No audit rows exist yet for push_subscriptions in the cloud (the
-- table ships with this branch), so no scrub of old rows is needed; locally, db reset starts empty.

CREATE OR REPLACE FUNCTION app.audit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_before jsonb;
  v_after  jsonb;
  v_org    uuid;
  v_plant  uuid;
  v_action text := tg_table_name || '.' || lower(tg_op);
  v_device uuid;
begin
  -- Columns are read through jsonb so this one function works on tables without them.
  -- Security L1: pin_hash and the lockout counters are never written to audit_log.
  v_after := to_jsonb(new) - 'pin_hash' - 'failed_pin_attempts' - 'locked_until';
  if tg_op = 'UPDATE' then
    v_before := to_jsonb(old) - 'pin_hash' - 'failed_pin_attempts' - 'locked_until';
    if tg_table_name = 'entry_staff'
       and (to_jsonb(old) ->> 'pin_hash') is distinct from (to_jsonb(new) ->> 'pin_hash') then
      v_action := 'entry_staff.pin_set';
    elsif v_before = v_after then
      return null;  -- no-op update
    elsif tg_table_name = 'entry_staff' and (v_before - 'updated_at') = (v_after - 'updated_at') then
      return null;  -- D12: lockout-counter-only update
    end if;
    if tg_table_name = 'finished_goods_entries'
       and v_before ->> 'voided_at' is null and v_after ->> 'voided_at' is not null then
      v_action := 'finished_goods_entries.void';
    end if;
  end if;

  -- Security review H1 (2026-11-04): push subscription keys and endpoints never reach audit_log
  -- (owners/managers read it). Keep only the push service host. On a rebind to another org, the
  -- previous org's ids are dropped from "before" so they are not shown to the new org.
  if tg_table_name = 'push_subscriptions' then
    v_after := (v_after - 'endpoint' - 'p256dh' - 'auth')
               || pg_catalog.jsonb_build_object('endpoint_host',
                    pg_catalog.substring(to_jsonb(new) ->> 'endpoint', '^https?://([^/:?#]+)'));
    if v_before is not null then
      v_before := (v_before - 'endpoint' - 'p256dh' - 'auth')
                  || pg_catalog.jsonb_build_object('endpoint_host',
                       pg_catalog.substring(to_jsonb(old) ->> 'endpoint', '^https?://([^/:?#]+)'));
      if v_before ->> 'org_id' is distinct from v_after ->> 'org_id' then
        v_before := v_before - 'org_id' - 'plant_id' - 'user_id' - 'user_agent';
      end if;
    end if;
  end if;

  if tg_table_name = 'organizations' then
    v_org := new.id;
  else
    v_org := (v_after ->> 'org_id')::uuid;
  end if;
  if tg_table_name = 'plants' then
    v_plant := new.id;
  else
    v_plant := (v_after ->> 'plant_id')::uuid;
  end if;

  -- devices exists from migration create_devices_and_pairing on (plpgsql resolves at call time).
  select d.id into v_device from public.devices d
   where d.user_id = (select auth.uid()) and d.revoked_at is null;

  insert into public.audit_log (org_id, plant_id, actor_user_id, actor_device_id, action, entity, entity_id, before, after)
  values (v_org, v_plant, (select auth.uid()), v_device, v_action, tg_table_name,
          (v_after ->> 'id')::uuid, v_before, v_after);
  return null;
end;
$function$;
comment on function app.audit() is
  '§4.5/H2 AFTER INSERT/UPDATE: writes audit_log with before/after (pin_hash and lockout counters stripped, lockout-only updates skipped; D12, security L1). push_subscriptions: endpoint, p256dh and auth are never written (only endpoint_host), and a cross-org rebind drops the previous org''s ids from before (security review H1, 2026-11-04).';
