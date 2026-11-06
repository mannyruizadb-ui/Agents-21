-- Security review 2026-11-06 (BLOCK at 35cf7bb): history leaks to non-owners.
--
-- H1  audit_log was readable by managers (all history, with who-entered keys in before/after). Now
--     OWNER-only, and app.audit() strips entered_by, staff_id, created_by, voided_by, updated_by and
--     updated_by_staff_id from the images (owner 2026-11-04: no names anywhere). Existing audit rows are
--     NOT rewritten here (the audit log is append-only history): see the HANDOFF for an optional,
--     owner-approved scrub of rows written before this migration.
-- M1  queue_items: the owner reads everything; manager / lead / viewer read OPEN items (queued,
--     in_progress) plus items completed (done) during their area's CURRENT shift instance; a display
--     reads its own area as before. get_queue (definer) and queue_board (open items only) are unchanged.
-- L1  shift_crew_hours: owner-only SELECT.

drop policy audit_log_select on public.audit_log;
create policy audit_log_select on public.audit_log for select to authenticated
  using (case when plant_id is null then (select app.has_org_role(org_id, '{owner}'))
              else (select app.has_role(plant_id, '{owner}')) end);

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

  -- Security review 2026-11-06 H1 (owner: no names anywhere): who entered / created / updated /
  -- voided a row never reaches the audit images (audit_log.actor_user_id stays: the audit's own actor).
  v_after := v_after - 'entered_by' - 'staff_id' - 'created_by' - 'voided_by' - 'updated_by' - 'updated_by_staff_id';
  if v_before is not null then
    v_before := v_before - 'entered_by' - 'staff_id' - 'created_by' - 'voided_by' - 'updated_by' - 'updated_by_staff_id';
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
  '§4.5/H2 AFTER INSERT/UPDATE: writes audit_log with before/after (pin_hash and lockout counters stripped, lockout-only updates skipped; D12, security L1). push_subscriptions: endpoint, p256dh and auth are never written (only endpoint_host), and a cross-org rebind drops the previous org''s ids from before (security review H1, 2026-11-04). Who-entered keys (entered_by, staff_id, created_by, voided_by, updated_by, updated_by_staff_id) are stripped from before/after (security review 2026-11-06 H1).';

drop policy queue_items_select on public.queue_items;
create policy queue_items_select on public.queue_items for select to authenticated
  using ((select app.has_role(plant_id, '{owner}'))
         or ((select app.has_role(plant_id, '{manager,lead,viewer}'))
             and (status in ('queued', 'in_progress')
                  or (status = 'done' and exists (
                        select 1 from public.shift_instances si
                         where si.area_id = queue_items.area_id and si.plant_id = queue_items.plant_id
                           and si.skipped_at is null and si.starts_at <= now() and si.ends_at > now()
                           and queue_items.completed_at >= si.starts_at and queue_items.completed_at < si.ends_at))))
         or ((select app.is_display(plant_id)) and area_id = (select (app.my_device()).area_id)));

drop policy shift_crew_hours_select on public.shift_crew_hours;
create policy shift_crew_hours_select on public.shift_crew_hours for select to authenticated
  using ((select app.has_role(plant_id, '{owner}')));
