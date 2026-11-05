-- Owner 2026-11-05: ALL managers get machine-down alerts. notify_machine_down now defaults to true for
-- owner and manager memberships (lead, viewer, display stay false). Existing active manager memberships
-- are switched on (DATA; the column shipped in this branch, so no owner choice is overwritten in the
-- cloud). The owner can still turn anyone off with set_alert_recipient.

create or replace function app.default_notify_machine_down()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.notify_machine_down := coalesce(new.notify_machine_down, new.role in ('owner', 'manager'));
  return new;
end;
$$;
comment on function app.default_notify_machine_down() is
  'BEFORE INSERT on memberships: notify_machine_down defaults to true for owner and manager memberships and false for other roles when the insert leaves it null (owner 2026-11-04 / 2026-11-05).';

update public.memberships
   set notify_machine_down = true
 where role = 'manager' and revoked_at is null and not notify_machine_down;

comment on column public.memberships.notify_machine_down is
  'Owner 2026-11-04/05: this member gets machine-down push alerts for the membership''s plant (org-wide: every plant). Default true for owner and manager, false otherwise; only owner/manager memberships are ever alerted. Changed by the owner via set_alert_recipient.';
