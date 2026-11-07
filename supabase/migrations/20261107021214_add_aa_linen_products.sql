-- AA Linen products, customer-group rights, customers for leads/displays, void a delivery (owner 2026-11-07,
-- "green light").
--
-- * DATA (idempotent; supabase/seed.sql carries the same for fresh databases). AA Linen's wash groups become
--   12: White aprons, Black aprons, White napkins, Colored napkins, White tablecloths, Colored tablecloths,
--   Cotton tablecloths, Kitchen towels, Mats (es "Alfombras"), Stained white napkins, Stained white
--   tablecloths, Stained hotel towels, with the owner's Spanish names and formulas (by external_no):
--   stained → 5; white aprons 5; black aprons 4; white napkins 3; colored napkins 4; white tablecloths 3;
--   colored tablecloths 4; cotton tablecloths 3 (FLAG: no cotton tablecloth group of our own exists; 3 = our
--   White tablecloths' and our "Napkins – Cotton White" formula); kitchen towels 5; mats 1. Loads per bin
--   stay null except Mats = 4 (only set for groups created here; existing values are never overwritten).
--   The generic groups from 20261107003619 (Aprons, Napkins, Tablecloths) are RENAMED to White aprons /
--   White napkins / White tablecloths rather than deactivated: 20261107003619 ships in the same deploy as
--   this migration (the cloud is at 20261106133543), so they have no history anywhere that matters, and
--   renaming leaves no dead inactive groups behind. 20261107003619 itself is not edited (reviewed).
--   New colors (#4F46E5, #A21CAF, #BE185D, #4D7C0F) are ≥ 3:1 against the white card and the TV's dark
--   card (#0B0F14), and none is a color already used by a wash group.
-- * Customer wash groups (customer_id not null) are OWNER-only for insert and for update of ANY column
--   (was: only customer_id). Managers keep editing our own groups as before (incl. wash_formula_id; load
--   factors still need can_edit_load_factors). wash_formula_id was already in the owners' UPDATE grant.
-- * customers: leads and displays (of the plant) may now READ them (name), so tablets and TVs can show
--   "AA Linen". Viewers are unchanged (not asked).
-- * void_customer_delivery(p_delivery_id, p_reason): owner or manager of the plant voids a delivery once;
--   its queue items that are still queued and never started are cancelled; items in progress or done stay
--   and are reported back. Idempotent (a second call returns the first void, duplicate = true).

-- ── Owner-only customer groups ────────────────────────────────────────────
create or replace function app.guard_wash_group_customer()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    return new;                                  -- service role / migrations
  end if;
  if not app.has_role(new.plant_id, '{owner,manager,lead,viewer}') then
    return new;                                  -- RLS rejects it; no oracle
  end if;
  -- 2026-11-07: any insert or update of a customer's group (before or after the change) is owner-only.
  if new.customer_id is not null
     or (tg_op = 'UPDATE' and (old.customer_id is not null or new.customer_id is distinct from old.customer_id)) then
    if not app.has_role(new.plant_id, '{owner}') then
      raise exception 'NOT_AUTHORIZED' using detail = 'customer wash groups: owner only';
    end if;
  end if;
  return new;
end;
$$;
comment on function app.guard_wash_group_customer() is
  'Owner 2026-11-06 (A), widened 2026-11-07: only owners may insert a customer''s wash group, update any column of one, or set / change wash_groups.customer_id. Managers keep their edits of our own groups. Trigger.';
drop trigger wash_groups_guard_customer on public.wash_groups;
create trigger wash_groups_guard_customer before insert or update on public.wash_groups
  for each row execute function app.guard_wash_group_customer();

-- ── customers: leads and displays read ────────────────────────────────────
drop policy customers_select on public.customers;
create policy customers_select on public.customers for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead}')) or (select app.is_display(plant_id)));
comment on table public.customers is
  'Owner 2026-11-06 (A): outside customers whose goods ADB washes separately (first: AA Linen). Their goods are their own wash groups (wash_groups.customer_id). Owners/managers/leads and the plant''s displays read (leads + displays 2026-11-07, to show the customer name); owners write (column grants). Deactivate, never delete.';

-- ── DATA: AA Linen's 12 products (ADB plant; idempotent) ──────────────────
-- Generic → white (no history: see the header).
update public.wash_groups g
   set name = r.new_name
  from public.customers c
  join public.plants p on p.id = c.plant_id and p.name = 'Miami'
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values ('Aprons', 'White aprons'), ('Napkins', 'White napkins'), ('Tablecloths', 'White tablecloths')) r(old_name, new_name)
 where c.name = 'AA Linen' and g.customer_id = c.id and g.plant_id = c.plant_id and g.name = r.old_name
   and not exists (select 1 from public.wash_groups x
                    where x.plant_id = c.plant_id and x.customer_id = c.id and x.name = r.new_name);

insert into public.wash_groups (org_id, plant_id, customer_id, name, name_i18n, color_hex, sort_order,
                                loads_per_bin, allow_bin_estimates)
select c.org_id, c.plant_id, c.id, v.name, pg_catalog.jsonb_build_object('es', v.es), v.color, v.sort_order,
       v.per_bin, v.per_bin is not null
  from public.customers c
  join public.plants p on p.id = c.plant_id and p.name = 'Miami'
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
   ('Kitchen towels',            'Toallas de cocina',             '#C2410C', 1000, null::numeric),
   ('White aprons',              'Delantales blancos',            '#0E7490', 1010, null),
   ('Black aprons',              'Delantales negros',             '#4F46E5', 1015, null),
   ('Mats',                      'Alfombras',                     '#A16207', 1020, 4),
   ('White napkins',             'Servilletas blancas',           '#15803D', 1030, null),
   ('Colored napkins',           'Servilletas de color',          '#A21CAF', 1035, null),
   ('White tablecloths',         'Manteles blancos',              '#E11D48', 1040, null),
   ('Colored tablecloths',       'Manteles de color',             '#BE185D', 1043, null),
   ('Cotton tablecloths',        'Manteles de algodón',           '#4D7C0F', 1046, null),
   ('Stained white napkins',     'Servilletas blancas manchadas', '#9333EA', 1050, null),
   ('Stained white tablecloths', 'Manteles blancos manchados',    '#0284C7', 1060, null),
   ('Stained hotel towels',      'Toallas de hotel manchadas',    '#059669', 1070, null)) as v(name, es, color, sort_order, per_bin)
 where c.name = 'AA Linen'
   and not exists (select 1 from public.wash_groups g
                    where g.plant_id = c.plant_id and g.customer_id = c.id and g.name = v.name);

-- Spanish names and formulas for all 12 (the owner's values; formula by the plant's external_no).
update public.wash_groups g
   set name_i18n = g.name_i18n || pg_catalog.jsonb_build_object('es', v.es),
       wash_formula_id = f.id
  from public.customers c
  join public.plants p on p.id = c.plant_id and p.name = 'Miami'
  join public.organizations o on o.id = p.org_id and o.slug = 'americas-dust-busters'
 cross join (values
   ('Kitchen towels',            'Toallas de cocina',             '5'),
   ('White aprons',              'Delantales blancos',            '5'),
   ('Black aprons',              'Delantales negros',             '4'),
   ('Mats',                      'Alfombras',                     '1'),
   ('White napkins',             'Servilletas blancas',           '3'),
   ('Colored napkins',           'Servilletas de color',          '4'),
   ('White tablecloths',         'Manteles blancos',              '3'),
   ('Colored tablecloths',       'Manteles de color',             '4'),
   ('Cotton tablecloths',        'Manteles de algodón',           '3'),
   ('Stained white napkins',     'Servilletas blancas manchadas', '5'),
   ('Stained white tablecloths', 'Manteles blancos manchados',    '5'),
   ('Stained hotel towels',      'Toallas de hotel manchadas',    '5')) as v(name, es, formula_no)
  join public.wash_formulas f on true
 where c.name = 'AA Linen' and g.customer_id = c.id and g.plant_id = c.plant_id and g.name = v.name
   and f.plant_id = c.plant_id and f.external_no = v.formula_no;

-- ── void_customer_delivery ────────────────────────────────────────────────
create type public.customer_delivery_void_result as (
  delivery_id         uuid,
  voided_at           timestamptz,
  cancelled_item_ids  uuid[],
  kept_items          jsonb,
  duplicate           boolean
);
comment on type public.customer_delivery_void_result is
  'void_customer_delivery result: the delivery, when it was voided, the queue items this call cancelled (empty on a retry), kept_items = its queue items that were NOT cancelled ([{queue_item_id, status, loads_started}], e.g. already in progress or done), and duplicate = true when it was already voided.';

create function public.void_customer_delivery(p_delivery_id uuid, p_reason text)
returns public.customer_delivery_void_result
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_d         record;
  v_reason    text;
  v_area      uuid;
  v_cancelled uuid[] := '{}';
  v_id        uuid;
  v_kept      jsonb;
  v_dup       boolean := false;
  v_at        timestamptz;
begin
  -- Role check FIRST: a missing delivery and another tenant's delivery give the same answer.
  select d.id, d.org_id, d.plant_id into v_d from public.customer_deliveries d where d.id = p_delivery_id;
  if v_d.id is null or not app.has_role(v_d.plant_id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'void_customer_delivery requires owner or manager on the delivery''s plant';
  end if;
  v_reason := app.clean_note(p_reason, 200, 'reason');
  if v_reason is null then
    raise exception 'VALIDATION_FAILED' using detail = 'reason: required (1–200 characters)';
  end if;
  -- Serialize with start_washer_load and the queue RPCs of every area the delivery's items are in (in a
  -- fixed order), so an item cannot start while it is being cancelled.
  for v_area in select distinct q.area_id from public.customer_delivery_lines l
                  join public.queue_items q on q.id = l.queue_item_id and q.plant_id = l.plant_id
                 where l.delivery_id = v_d.id and l.plant_id = v_d.plant_id
                 order by q.area_id loop
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('queue:' || v_area::text, 0));
  end loop;
  select d.voided_at into v_at from public.customer_deliveries d where d.id = v_d.id for update;
  if v_at is not null then
    v_dup := true;                               -- idempotent retry: nothing changes
  else
    update public.customer_deliveries d
       set voided_at = pg_catalog.now(), voided_by = (select auth.uid()), void_reason = v_reason
     where d.id = v_d.id
    returning d.voided_at into v_at;
    for v_id in select q.id from public.customer_delivery_lines l
                  join public.queue_items q on q.id = l.queue_item_id and q.plant_id = l.plant_id
                 where l.delivery_id = v_d.id and q.status = 'queued' and q.loads_started = 0
                 order by l.line_no
                   for update of q loop
      update public.queue_items q set status = 'cancelled', updated_by = (select auth.uid())
       where q.id = v_id;
      v_cancelled := v_cancelled || v_id;
    end loop;
  end if;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
           'queue_item_id', q.id, 'status', q.status, 'loads_started', q.loads_started) order by l.line_no), '[]'::jsonb)
    into v_kept
    from public.customer_delivery_lines l
    join public.queue_items q on q.id = l.queue_item_id and q.plant_id = l.plant_id
   where l.delivery_id = v_d.id and not (q.id = any (v_cancelled)) and q.status <> 'cancelled';
  return (v_d.id, v_at, v_cancelled, v_kept, v_dup)::public.customer_delivery_void_result;
end;
$$;
comment on function public.void_customer_delivery(uuid, text) is
  'Owner 2026-11-07 RPC (owner or manager of the delivery''s plant; definer, role check first, no oracle): voids an outside customer''s delivery ONCE (voided_at/by, void_reason 1–200 clean characters, required) and cancels its queue items that are still queued and never started (status queued, loads_started 0), under the washroom queue lock. Items already in progress or done stay as they are and are returned in kept_items [{queue_item_id, status, loads_started}]. Its customer_delivery alert becomes stale (payload voided = true). A second call changes nothing and returns duplicate = true. Returns customer_delivery_void_result {delivery_id, voided_at, cancelled_item_ids, kept_items, duplicate}. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.void_customer_delivery(uuid, text) from public, anon;
grant execute on function public.void_customer_delivery(uuid, text) to authenticated, service_role;
