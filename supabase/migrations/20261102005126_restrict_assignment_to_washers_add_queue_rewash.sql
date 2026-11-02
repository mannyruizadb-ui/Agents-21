-- Owner answers 2026-11-02 (follow-up to 20261102003728 / 20261102003730). Queue domain only.
--
-- 1. Washers only. queue_items.assigned_machine_id may name only a machine of kind 'washer' in the item's
--    own area. Enforced by a pure composite FK, with no SECURITY DEFINER lookup, so there is no oracle surface:
--      * machines gets unique (id, area_id, kind) as the FK target (it replaces unique (id, area_id),
--        whose only user was the FK being replaced);
--      * queue_items.assigned_machine_kind is a STORED GENERATED column: 'washer' when a machine is
--        assigned, else null. Clients cannot write it (generated), so the FK always demands a washer;
--      * FK (assigned_machine_id, area_id, assigned_machine_kind) → machines(id, area_id, kind), MATCH SIMPLE:
--        unassigned rows (both null) are not checked. A dryer, an ironer, a machine of another area,
--        plant or tenant, and a missing UUID all give the same 23503.
--    Security L2 (2026-11-02 review), owner/meta decision: when an item is completed or cancelled,
--    assigned_machine_id is LEFT AS IS (history of which washer ran it). Consequence, by design: the FK is
--    NO ACTION, so a machine's area_id and kind cannot change while any queue item (open, completed or
--    cancelled) references it. To move or re-kind a machine, add a new machine row and deactivate the old one.
--
-- 2. Rewash comes from finishing (owner): the finishing crew pulls items that came out dirty and sends them
--    back, so a rewash is a QUEUE ITEM decision, not the washman's. queue_items.is_rewash boolean not null
--    default false; writable by the existing queue_items policies (owner/manager C U), versioned and audited
--    by the existing triggers. The M2 start-load RPC copies it to washer_cycles.is_rewash, which keeps the
--    reconciliation rule from 20261102003730 (rewash never counts in standard_loads).

-- ── 1. Washer-only assignment ─────────────────────────────────────────────
alter table public.machines
  add constraint machines_id_area_kind_key unique (id, area_id, kind);

alter table public.queue_items
  drop constraint queue_items_assigned_machine_fkey;
drop index public.queue_items_assigned_machine_area_idx;
alter table public.machines
  drop constraint machines_id_area_key;

alter table public.queue_items
  add column assigned_machine_kind app.machine_kind
    generated always as (case when assigned_machine_id is not null then 'washer'::app.machine_kind end) stored,
  add constraint queue_items_assigned_washer_fkey
    foreign key (assigned_machine_id, area_id, assigned_machine_kind) references public.machines(id, area_id, kind);
create index queue_items_assigned_washer_idx on public.queue_items (assigned_machine_id, area_id, assigned_machine_kind);

comment on column public.queue_items.assigned_machine_kind is
  'Generated: ''washer'' when assigned_machine_id is set, else null. Part of the FK to machines(id, area_id, kind), so only a washer of the item''s own area can be assigned. Not writable.';
comment on column public.queue_items.assigned_machine_id is
  'Owner 2026-11-02: the WASHER the owner assigned this work to; null = next free washer. Must be a machine of kind washer in the item''s own area (composite FK with area_id and assigned_machine_kind). Changing it bumps version and is audited. Kept when the item is completed or cancelled (history), so a referenced machine''s area and kind are fixed (NO ACTION FK).';
comment on constraint machines_id_area_kind_key on public.machines is
  'Target of queue_items_assigned_washer_fkey. While a queue item references a machine, its area_id and kind cannot change (NO ACTION): add a new machine and deactivate the old one instead.';

-- ── 2. Rewash queue items ─────────────────────────────────────────────────
alter table public.queue_items
  add column is_rewash boolean not null default false;
comment on column public.queue_items.is_rewash is
  'Owner 2026-11-02: true = goods sent back by finishing because they came out dirty. Set by owner/manager on the queue item; the M2 start-load RPC copies it to washer_cycles.is_rewash, so rewash loads never count as new goods in reconciliation.';

-- ── queue_board: same columns as 20261102003728, plus is_rewash at the end ──
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
       q.is_rewash                                     -- sent back by finishing
  from public.queue_items q
  join public.wash_groups g on g.id = q.wash_group_id
  left join public.item_types i on i.id = q.item_type_id
  left join public.machines m on m.id = q.assigned_machine_id
 where q.status in ('queued', 'in_progress');
comment on view public.queue_board is
  '§4.6 Open queue (queued/in_progress) per area: wash group names in all languages, plus the optional item; qty_loads via app.to_loads (piece/pack approximate, null without a factor); assigned_machine_id/name = the washer the owner assigned (null = next free washer); is_rewash = goods sent back by finishing. Order by is_rush desc, position asc.';

revoke all on public.queue_board from anon, authenticated;
grant select on public.queue_board to authenticated;
