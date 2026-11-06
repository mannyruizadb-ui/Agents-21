-- Owner decision 2026-11-04 (round 2): no "entered by" names on any screen, the owner's included.
-- current_soil_estimates was the only public view exposing who entered a row (entered_by, staff_id
-- and entered_by_name via entry_staff). It is recreated without them; every other view was checked
-- (queue_board, washroom_by_shift, finished_by_shift, daily_reconciliation, entry_staff_public) and
-- none carries entered_by / created_by / updated_by / voided_by / staff_id. entry_staff_public keeps
-- display_name: it is the PIN picker's list of people, not attribution of any row.
-- Who entered a row is still STORED (A8 attribution, audit) on the tables; it is just not served by
-- the views. Same column order otherwise, so existing selects keep working.

drop view public.current_soil_estimates;
create view public.current_soil_estimates with (security_invoker = true) as
select distinct on (e.plant_id, e.wash_group_id)
       e.org_id,
       e.plant_id,
       e.wash_group_id,
       g.name                                                          as wash_group_name,
       g.name_i18n                                                     as wash_group_name_i18n,
       e.id                                                            as estimate_id,
       e.qty,
       e.unit,
       app.to_loads(e.wash_group_id, null, e.qty, e.unit)              as qty_loads,
       app.to_loads(e.wash_group_id, null, e.qty, e.unit) is not null  as has_conversion,
       e.entered_at,
       floor(extract(epoch from (now() - e.entered_at)) / 60)::int     as age_minutes,
       case when now() - e.entered_at >= make_interval(mins => p.estimate_red_minutes) then 'red'
            when now() - e.entered_at >= make_interval(mins => p.estimate_amber_minutes) then 'amber'
            else 'ok' end                                              as freshness
  from public.soil_estimates e
  join public.plants p on p.id = e.plant_id
  join public.wash_groups g on g.id = e.wash_group_id
 order by e.plant_id, e.wash_group_id, e.entered_at desc, e.id desc;
comment on view public.current_soil_estimates is
  '§4.6 Latest soil estimate per wash group (by entered_at) with load equivalent via app.to_loads (basket / bin via the group''s loads_per_basket / loads_per_bin; null = no conversion), age and freshness (ok/amber/red per plant thresholds). No entered_by / staff / names (owner 2026-11-04).';
revoke all on public.current_soil_estimates from anon, authenticated;
grant select on public.current_soil_estimates to authenticated;
