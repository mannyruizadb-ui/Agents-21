-- Security review 2026-11-04 (push layer), M2 + M3:
--
-- M2  Endpoints must belong to a known Web Push service (the sender would otherwise POST to any
--     https URL a manager supplies): fcm.googleapis.com (Chrome/Android/Edge), updates.push.services
--     .mozilla.com (Firefox), *.push.apple.com (Safari/iOS), *.notify.windows.com (legacy Edge/WNS).
--     Same rule in the CHECK constraint (app.is_push_endpoint) and in save_push_subscription. No port,
--     no userinfo, no whitespace; ≤ 1000 characters.
--     At most 5 ACTIVE subscriptions per user. CHOSEN: the oldest is revoked (by updated_at, i.e. the
--     least recently saved), so a new phone always works and a lost one drops off by itself; refusing
--     would leave a user stuck after replacing devices.
-- M3  Rebinding an endpoint that belongs to ANOTHER user happens only when p256dh and auth match the
--     stored values (the same browser re-subscribing under a new account). Otherwise nothing changes
--     and the caller gets the same (empty) response, so an attacker who learned an endpoint can
--     neither hijack nor detect it. The caller's own endpoint may always rotate its keys.
-- save_push_subscription now returns void (it returned the row id): the client never needed it, and
-- returning nothing keeps M3's "same response" honest. Breaking only for code that read the id.

create function app.is_push_endpoint(p text)
returns boolean language sql immutable set search_path = '' as $$
  select p is not null
     and pg_catalog.char_length(p) <= 1000
     and p ~* '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|([a-z0-9-]+\.)+push\.apple\.com|([a-z0-9-]+\.)+notify\.windows\.com)/[^[:space:][:cntrl:]]*$';
$$;
comment on function app.is_push_endpoint(text) is
  'Security review M2 (2026-11-04): true for an https URL (≤ 1000 chars, no port/userinfo/whitespace) on an allow-listed Web Push host: fcm.googleapis.com, updates.push.services.mozilla.com, *.push.apple.com, *.notify.windows.com.';
revoke all on function app.is_push_endpoint(text) from public, anon, authenticated;
grant execute on function app.is_push_endpoint(text) to service_role;

alter table public.push_subscriptions
  drop constraint push_subscriptions_endpoint_https,
  add constraint push_subscriptions_endpoint_allowed check (app.is_push_endpoint(endpoint)),
  add column updated_at timestamptz not null default now();
comment on column public.push_subscriptions.updated_at is
  'Last time this subscription was saved (subscribe, re-subscribe or rebind). The 5-per-user cap revokes the least recently saved.';
grant select (updated_at) on public.push_subscriptions to authenticated;
create index push_subscriptions_user_active_idx on public.push_subscriptions (user_id, updated_at desc) where revoked_at is null;

drop function public.save_push_subscription(uuid, text, text, text, text);
create function public.save_push_subscription(
  p_plant_id   uuid,
  p_endpoint   text,
  p_p256dh     text,
  p_auth       text,
  p_user_agent text default null)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare
  v_plant record;
  v_ua    text;
  v_id    uuid;
  v_me    uuid := (select auth.uid());
begin
  -- Role check FIRST: a missing plant and another tenant's plant give the same answer.
  select p.id, p.org_id into v_plant from public.plants p where p.id = p_plant_id;
  if v_plant.id is null or v_me is null or not app.has_role(v_plant.id, '{owner,manager}') then
    raise exception 'NOT_AUTHORIZED' using detail = 'save_push_subscription requires owner or manager on the plant';
  end if;
  if not app.is_push_endpoint(p_endpoint) then
    raise exception 'VALIDATION_FAILED' using detail = 'endpoint: an https URL of a known push service (FCM, Mozilla, Apple, Windows), at most 1000 characters';
  end if;
  if p_p256dh is null or pg_catalog.char_length(p_p256dh) not between 80 and 100 or p_p256dh !~ '^[A-Za-z0-9_-]+={0,2}$' then
    raise exception 'VALIDATION_FAILED' using detail = 'p256dh: base64url, 80–100 characters';
  end if;
  if p_auth is null or pg_catalog.char_length(p_auth) not between 16 and 32 or p_auth !~ '^[A-Za-z0-9_-]+={0,2}$' then
    raise exception 'VALIDATION_FAILED' using detail = 'auth: base64url, 16–32 characters';
  end if;
  v_ua := app.clean_note(p_user_agent, 300, 'user_agent');

  -- M3: an existing endpoint moves to the caller only if it is already the caller's, or the keys
  -- prove it is the same browser. Otherwise no row is touched and the response is the same.
  insert into public.push_subscriptions as s (org_id, plant_id, user_id, endpoint, p256dh, auth, user_agent, updated_at)
  values (v_plant.org_id, v_plant.id, v_me, p_endpoint, p_p256dh, p_auth, v_ua, pg_catalog.clock_timestamp())
  on conflict (endpoint) do update
     set org_id = excluded.org_id, plant_id = excluded.plant_id, user_id = excluded.user_id,
         p256dh = excluded.p256dh, auth = excluded.auth, user_agent = excluded.user_agent,
         revoked_at = null, updated_at = excluded.updated_at
   where s.user_id = excluded.user_id or (s.p256dh = excluded.p256dh and s.auth = excluded.auth)
  returning s.id into v_id;

  if v_id is not null then
    -- M2 cap: at most 5 active subscriptions per user; the least recently saved are revoked.
    update public.push_subscriptions s
       set revoked_at = pg_catalog.now()
     where s.id in (select x.id from public.push_subscriptions x
                     where x.user_id = v_me and x.revoked_at is null
                     order by x.updated_at desc, x.created_at desc, x.id desc
                     offset 5);
  end if;
end;
$$;
comment on function public.save_push_subscription(uuid, text, text, text, text) is
  'Owner 2026-11-04 RPC (owner/manager of p_plant_id; definer, role check first): saves this browser''s Web Push subscription for machine-down alerts. endpoint must be an https URL of an allow-listed push service (fcm.googleapis.com, updates.push.services.mozilla.com, *.push.apple.com, *.notify.windows.com; ≤ 1000 chars); p256dh base64url 80–100 chars; auth base64url 16–32 chars; user_agent ≤ 300 (optional). Upsert by endpoint: the caller''s own endpoint is updated and un-revoked; another user''s endpoint is rebound only when p256dh and auth match the stored ones (else nothing changes, same response: security M3). At most 5 active subscriptions per user: the least recently saved are revoked. Returns nothing. Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';
revoke all on function public.save_push_subscription(uuid, text, text, text, text) from public, anon;
grant execute on function public.save_push_subscription(uuid, text, text, text, text) to authenticated, service_role;
