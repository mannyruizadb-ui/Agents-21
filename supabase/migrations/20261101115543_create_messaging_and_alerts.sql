-- M1 · display broadcast messages + alert dedupe log (PRD D3, B3, D4; §4.4; §4.7).

create table public.display_messages (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  plant_id    uuid not null,
  area_id     uuid,                                       -- null = all displays
  body        text not null check (char_length(body) between 1 and 140 and app.is_clean_text(body)),
  body_lang   text not null references public.languages(code),
  body_i18n   jsonb not null default '{}'::jsonb check (jsonb_typeof(body_i18n) = 'object'),
  severity    app.msg_severity not null default 'info',
  starts_at   timestamptz not null default now(),
  expires_at  timestamptz not null,
  retracted_at timestamptz,
  created_by  uuid not null references auth.users(id),
  created_at  timestamptz not null default now(),
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  foreign key (area_id, plant_id) references public.areas(id, plant_id),
  check (expires_at > starts_at and expires_at <= starts_at + interval '12 hours')
);
alter table public.display_messages enable row level security;
create index display_messages_plant_org_idx on public.display_messages (plant_id, org_id);
create index display_messages_area_plant_idx on public.display_messages (area_id, plant_id);
create index display_messages_body_lang_idx on public.display_messages (body_lang);
create index display_messages_created_by_idx on public.display_messages (created_by);
create index display_messages_active_idx on public.display_messages (plant_id, expires_at) where retracted_at is null;

-- alert_events: written by Edge Functions / cron with the service role. §4.7 grants no client
-- access (recipients are email addresses), so RLS is on with no policies.
create table public.alert_events (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  plant_id    uuid not null,
  -- Deviation from §4.4: + 'shift_generation_failed' (architect N1d, app.generate_all_shift_instances).
  kind        text not null check (kind in ('estimate_stale','device_offline','import_failed','shift_generation_failed')),
  subject_id  uuid,                                       -- item_type / device / batch / plant
  shift_instance_id uuid,
  sent_at     timestamptz not null default now(),
  recipients  text[] not null,
  foreign key (plant_id, org_id) references public.plants(id, org_id),
  -- Deviation from §4.4: the shift instance must belong to the same plant.
  foreign key (shift_instance_id, plant_id) references public.shift_instances(id, plant_id),
  unique nulls not distinct (kind, subject_id, shift_instance_id)   -- dedupe: 1 per shift
);
alter table public.alert_events enable row level security;
create index alert_events_plant_org_idx on public.alert_events (plant_id, org_id);
create index alert_events_shift_plant_idx on public.alert_events (shift_instance_id, plant_id);

-- ── Triggers ──────────────────────────────────────────────────────────────
create trigger display_messages_check_languages
  before insert or update of body_lang, body_i18n, plant_id on public.display_messages
  for each row execute function app.check_languages();
create trigger display_messages_audit after insert or update on public.display_messages
  for each row execute function app.audit();

-- ── Realtime ──────────────────────────────────────────────────────────────
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.display_messages;
  end if;
end;
$$;

-- ── RLS policies (§4.7: owner/manager R C U; lead, viewer R; display R own area or all-areas) ──
create policy display_messages_select on public.display_messages for select to authenticated
  using ((select app.has_role(plant_id, '{owner,manager,lead,viewer}'))
         or ((select app.is_display(plant_id))
             and (area_id is null or area_id = (select (app.my_device()).area_id))));
create policy display_messages_insert on public.display_messages for insert to authenticated
  with check ((select app.has_role(plant_id, '{owner,manager}')) and created_by = (select auth.uid()));
create policy display_messages_update on public.display_messages for update to authenticated
  using ((select app.has_role(plant_id, '{owner,manager}')))
  with check ((select app.has_role(plant_id, '{owner,manager}')));
