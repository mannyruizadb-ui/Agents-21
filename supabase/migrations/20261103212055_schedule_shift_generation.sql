-- Nightly shift-instance generation with pg_cron (PRD A6, §4.5; M1 part 2 carry-over).
-- pg_cron is available on Supabase (cloud and the local image, where it is in shared_preload_libraries).
-- Safe to re-run: the job is unscheduled by name if it exists, then scheduled again.
-- The job runs app.generate_all_shift_instances(14) at 03:15 UTC (22:15 / 23:15 Miami): every plant,
-- the next 14 days, idempotent; a failing plant is logged in alert_events and the others continue.
-- It also runs once now, so instances exist as soon as this migration is applied (on a fresh local
-- reset there are no plants yet and it returns 0; the seed generates its own week).
-- Guard: if pg_cron cannot be created (an image without it), the migration only warns and the
-- schedule must be added later; generation still runs once.

do $$
begin
  if exists (select 1 from pg_catalog.pg_available_extensions where name = 'pg_cron') then
    begin
      create extension if not exists pg_cron with schema pg_catalog;
    exception when others then
      raise warning 'pg_cron not created (%): schedule generate_all_shift_instances manually', sqlerrm;
    end;
  else
    raise warning 'pg_cron is not available: schedule generate_all_shift_instances manually';
  end if;

  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'generate-shift-instances';
    perform cron.schedule('generate-shift-instances', '15 3 * * *',
                          'select app.generate_all_shift_instances(14)');
  end if;
end;
$$;

select app.generate_all_shift_instances(14);
