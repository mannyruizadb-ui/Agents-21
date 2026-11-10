-- Owner 2026-11-10: the production day starts at 10:00 plant-local (was 12:00), so the finishing Day shift
-- (10:00–16:00) counts toward the day it starts. Cloud shifts (verified by the coordinator): washroom Night
-- 00–12, Evening 14–24 / 15–24; finishing Night 00–10 / 00–05, Day 10–16, Evening 16–24 / 17–24. With 10:00
-- every shift keeps its production day except finishing Day, which moves to its own date (Tue 10:00 Day →
-- Tuesday; washroom Tue 00:00 Night → Monday; washroom Tue 14:00 Evening → Tuesday).
--
-- * Data: plants still on the old 12:00 move to 10:00. The existing AFTER UPDATE OF production_day_start
--   trigger (plants_redate_future_shift_instances, 20261101212510) re-dates ONLY the instances that have not
--   started yet (starts_at > now()); started instances keep their production_date. Re-dates are audited
--   by shift_instances_audit. Exception (security review L2): rows WITHOUT a shift instance (off-shift
--   finished goods, off-shift washer starts) are dated from their timestamp with the CURRENT setting, so
--   such a row made between 10:00 and 11:59 local moves to that calendar day. Checked before deploy on
--   2026-11-10: the cloud had 0 finished-goods entries, so nothing moved.
-- * The column default becomes 10:00 (new plants, local seed). Comments that said noon / 12:00 are updated.

alter table public.plants alter column production_day_start set default '10:00';

update public.plants set production_day_start = '10:00' where production_day_start = '12:00';

comment on column public.plants.production_day_start is
  'Owner decisions 2026-11-01 / 2026-11-10: plant-local time the production day starts (default 10:00 since 2026-11-10, was 12:00; whole minutes). A production day runs from this time to the same time the next day. Changing it re-dates only shift instances that have not started yet.';
comment on function app.production_date(timestamptz, text, time) is
  'Production day of p_ts: the plant-local date of (local time − production_day_start). With 10:00 (the default since 2026-11-10), Tue 09:59 local → Monday, Tue 10:00 → Tuesday. DST-safe (local wall time). Used by shift_instances.production_date and the reporting views.';

-- RPC comments that named the old 12:00 → 12:00 window: same text with the plant setting named instead.
do $$
declare
  f regprocedure;
  v text;
begin
  foreach f in array array['public.get_day_report(uuid, date)'::regprocedure,
                           'public.get_finished_goods_entries(uuid, date, uuid, integer)'::regprocedure,
                           'public.get_off_queue_starts(uuid, date)'::regprocedure] loop
    v := pg_catalog.obj_description(f, 'pg_proc');
    v := replace(v, 'default 12:00 → 12:00', 'default 10:00 → 10:00 since 2026-11-10');
    v := replace(v, '12:00→12:00 plant-local', 'plants.production_day_start → same time next day, plant-local; 10:00 since 2026-11-10');
    execute format('comment on function %s is %L', f, v);
  end loop;
end;
$$;
