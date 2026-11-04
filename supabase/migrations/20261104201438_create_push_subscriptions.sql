-- Web Push subscriptions for machine-down alerts (owner 2026-11-04: free Web Push to the installed
-- app, not SMS). One row per browser push endpoint. Writes only through the definer RPCs below; a
-- user reads only their own rows, and never the keys (column grants): the keys are for the sender
-- (service role) alone.
--
-- Rebinding: an endpoint identifies one browser install. If another account signs in on that device
-- and subscribes, the row moves to that account (and plant) and is un-revoked, so the previous
-- account stops getting that device's alerts.

create table public.push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  plant_id    uuid not null,
  user_id     uuid not null references auth.users(id),
  endpoint    text not null unique
              constraint push_subscriptions_endpoint_https
              check (char_length(endpoint) between 9 and 1000 and endpoint ~ '^https://[^[:space:][:cntrl:]]+$'),
  p256dh      text not null
              constraint push_subscriptions_p256dh_b64url
              check (char_length(p256dh) between 80 and 100 and p256dh ~ '^[A-Za-z0-9_-]+={0,2}$'),
  auth        text not null
              constraint push_subscriptions_auth_b64url
              check (char_length(auth) between 16 and 32 and auth ~ '^[A-Za-z0-9_-]+={0,2}$'),
  user_agent  text check (char_length(user_agent) <= 300 and app.is_clean_text(user_agent)),
  created_at  timestamptz not null default now(),
  revoked_at  timestamptz,
  foreign key (plant_id, org_id) references public.plants(id, org_id)
);
alter table public.push_subscriptions enable row level security;
create index push_subscriptions_plant_org_idx on public.push_subscriptions (plant_id, org_id);
create index push_subscriptions_user_idx on public.push_subscriptions (user_id);
create index push_subscriptions_active_idx on public.push_subscriptions (plant_id, user_id) where revoked_at is null;
comment on table public.push_subscriptions is
  'Owner 2026-11-04: Web Push endpoints for machine-down alerts (one per browser install). Writes only via save_push_subscription / remove_push_subscription; a user reads only their own rows and never the keys (p256dh, auth), which only the service role (the send-alerts Edge Function) reads.';

create trigger push_subscriptions_audit after insert or update on public.push_subscriptions
  for each row execute function app.audit();

create policy push_subscriptions_select_own on public.push_subscriptions for select to authenticated
  using (user_id = (select auth.uid()));
revoke all on public.push_subscriptions from anon, authenticated;
grant select (id, org_id, plant_id, user_id, endpoint, user_agent, created_at, revoked_at)
  on public.push_subscriptions to authenticated;

-- ── save_push_subscription ────────────────────────────────────────────────
create function public.save_push_subscription(
  p_plant_id   uuid,
  p_endpoint   text,
  p_p256dh     text,
  p_auth       text,
  p_user_agent text default null)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare
  v_plant record;
  v_ua    text;
  v_id    uuid;
begin
  -- Role check FIRST: a missing plant and another tenant's plant give the same answer.
  select p.id, p.org_id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant.id is null or (select auth.uid()) is null or not app.has_role(v_plant.id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'save_push_subscription requires owner or manager on the plant';
  end if;
  if p_endpoint is null or pg_catalog.char_length(p_endpoint) > 1000 or p_endpoint !~ '^https://[^[:space:][:cntrl:]]+$' then
    raise exception 'VALIDATION_FAILED' using detail = 'endpoint: an https URL of at most 1000 characters';
  end if;
  if p_p256dh is null or pg_catalog.char_length(p_p256dh) not between 80 and 100 or p_p256dh !~ '^[A-Za-z0-9_-]+={0,2}$' then
    raise exception 'VALIDATION_FAILED' using detail = 'p256dh: base64url, 80–100 characters';
  end if;
  if p_auth is null or pg_catalog.char_length(p_auth) not between 16 and 32 or p_auth !~ '^[A-Za-z0-9_-]+={0,2}$' then
    raise exception 'VALIDATION_FAILED' using detail = 'auth: base64url, 16–32 characters';
  end if;
  v_ua := app.clean_note(p_user_agent, 300, 'user_agent');

  insert into public.push_subscriptions as s (org_id, plant_id, user_id, endpoint, p256dh, auth, user_agent)
  values (v_plant.org_id, v_plant.id, (select auth.uid()), p_endpoint, p_p256dh, p_auth, v_ua)
  on conflict (endpoint) do update
     set org_id = excluded.org_id, plant_id = excluded.plant_id, user_id = excluded.user_id,
         p256dh = excluded.p256dh, auth = excluded.auth, user_agent = excluded.user_agent, revoked_at = null
  returning s.id into v_id;
  return v_id;
end;
$$;
comment on function public.save_push_subscription(uuid, text, text, text, text) is
  'Owner 2026-11-04 RPC (owner/manager of p_plant_id; definer, role check first): saves this browser''s Web Push subscription for machine-down alerts. Upsert by endpoint: an existing endpoint is rebound to the caller and this plant, its keys replaced, and un-revoked. endpoint = https URL ≤ 1000 chars; p256dh base64url 80–100 chars; auth base64url 16–32 chars; user_agent ≤ 300 (optional). Returns the subscription id. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.save_push_subscription(uuid, text, text, text, text) from public, anon;
grant execute on function public.save_push_subscription(uuid, text, text, text, text) to authenticated, service_role;

-- ── remove_push_subscription ──────────────────────────────────────────────
create function public.remove_push_subscription(p_endpoint text)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
declare
  v_n int;
begin
  if (select auth.uid()) is null then
    raise exception 'NOT_AUTHORIZED' using detail = 'remove_push_subscription requires a signed-in user';
  end if;
  update public.push_subscriptions s
     set revoked_at = pg_catalog.now()
   where s.endpoint = p_endpoint and s.user_id = (select auth.uid()) and s.revoked_at is null;
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;
comment on function public.remove_push_subscription(text) is
  'Owner 2026-11-04 RPC (any signed-in user; definer): revokes the caller''s OWN subscription with this endpoint (sets revoked_at; never deleted). Returns true when one was revoked; false for an unknown endpoint, someone else''s, or one already revoked (the same answer: no oracle). Errors: NOT_AUTHORIZED (not signed in).';
revoke all on function public.remove_push_subscription(text) from public, anon;
grant execute on function public.remove_push_subscription(text) to authenticated, service_role;
