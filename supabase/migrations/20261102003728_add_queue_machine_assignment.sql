-- Owner decision 2026-11-02 (B): the owner can assign a queued load to a specific washer.
--
--   * queue_items.assigned_machine_id: null = "next free washer" (the default). When set, the machine
--     must be in the queue item's OWN AREA: composite FK (assigned_machine_id, area_id) →
--     machines(id, area_id). The queue item's (area_id, plant_id) FK and the machine's
--     (area_id, plant_id) FK make the plant match transitively, so a machine of another plant, another
--     tenant or another area (e.g. a washroom washer on a finishing-area item) is rejected with 23503.
--   * Writers: unchanged. The existing queue_items policies (owner/manager C U; lead, viewer R; display
--     R own area) cover the new column; app.bump_queue_version bumps version on every update, so an
--     assignment is an optimistic-concurrency write like a reorder; queue_items_audit records it.
--   * Machine kind is not restricted (a washroom item could name a dryer): the owner asked for washers,
--     and restricting by kind needs a definer lookup trigger; left to the UI and an owner question.
--
-- No SECURITY DEFINER code: the FK alone checks the reference, so a foreign machine UUID gives 23503
-- to every caller who passes RLS (no cross-tenant oracle).

alter table public.machines
  add constraint machines_id_area_key unique (id, area_id);   -- target for queue_items' composite FK

alter table public.queue_items
  add column assigned_machine_id uuid,
  add constraint queue_items_assigned_machine_fkey
    foreign key (assigned_machine_id, area_id) references public.machines(id, area_id);
create index queue_items_assigned_machine_area_idx on public.queue_items (assigned_machine_id, area_id);
comment on column public.queue_items.assigned_machine_id is
  'Owner 2026-11-02: the machine (washer) the owner assigned this work to; null = next free washer. Must be a machine of the item''s own area (composite FK with area_id). Changing it bumps version and is audited.';

-- queue_board: same columns as before (20261101214357), plus the assignment at the end.
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
       m.name                                          as assigned_machine_name
  from public.queue_items q
  join public.wash_groups g on g.id = q.wash_group_id
  left join public.item_types i on i.id = q.item_type_id
  left join public.machines m on m.id = q.assigned_machine_id
 where q.status in ('queued', 'in_progress');
comment on view public.queue_board is
  '§4.6 Open queue (queued/in_progress) per area: wash group names in all languages, plus the optional item; qty_loads via app.to_loads (piece/pack approximate, null without a factor); assigned_machine_id/name = the washer the owner assigned (null = next free washer). Order by is_rush desc, position asc.';

-- create or replace keeps the grants; restate them so the view's ACL is explicit here too.
revoke all on public.queue_board from anon, authenticated;
grant select on public.queue_board to authenticated;
