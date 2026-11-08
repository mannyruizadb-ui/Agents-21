-- Sign-in lockout hardening (owner-approved 2026-11-07, "green light"; security review 2026-11-07 BLOCK
-- follow-ups M3, M4, L1, plus the password-upgrade lookup for the pepper, H1).
--
-- * M3 (detection bypass): a parallel burst of 6 attempts locked the login inside sign_in_begin, so
--   sign_in_failed returned early and no account_locked alert was ever written. Now EVERY lock of a login
--   starts in one place, app.sign_in_start_lock, called by sign_in_begin AND sign_in_failed, which writes
--   the account_locked alert. Dedupe stays on the lock end (alert_events dedupe_key = locked_until epoch),
--   so one lock = one alert per plant, whichever RPC started it.
-- * M4 (no escalation): each new lock of a LOGIN that starts within 24 h after the end of its previous
--   lock doubles: 15 → 30 → 60 → 120 → 240 → 480 → 960 min, capped at 24 h. Columns lock_level (the level
--   of the latest lock, 0 = 15 min) and last_locked_until (the latest lock's end, kept after it expires).
--   A correct password (sign_in_succeeded) or an owner unlock deletes the row, so the level starts over.
--   IP locks keep the fixed 15 minutes (the IP limit is off unless a trusted header is configured: see the
--   sign-in function, M2). Sustained guessing on one login: 5 guesses, then 15 + 30 + 60 + … minutes,
--   i.e. about 40 guesses in the first 24 h and then 5 per day.
-- * account_locked default level = push for owners (was quiet).
-- * L1: the comment in sign_in_begin claimed a refused attempt is "not an attempt"; when the IP trips in
--   pass 2 the login's reservation from the same call stays counted. The comment now says so (behaviour
--   unchanged: conservative, it can only lock sooner).
-- * Purge: rows are kept until 24 h after their latest lock ended (the escalation memory).
-- * H1 (pepper): public.sign_in_account_state(p_login) tells the sign-in Edge Function whether a login is
--   an existing account whose stored password predates the pepper (app_metadata.pw_v is not 2), so the
--   function can verify the typed password once in its old form and re-store it peppered (one-time
--   upgrade, see supabase/functions/sign-in/logic.ts). Service role only.

-- ── Columns ───────────────────────────────────────────────────────────────
alter table public.sign_in_lockouts
  add column lock_level smallint not null default 0 check (lock_level between 0 and 10),
  add column last_locked_until timestamptz;
comment on column public.sign_in_lockouts.lock_level is
  'M4 (2026-11-07): level of the latest lock of this key (0 = 15 min, each level doubles, capped at 24 h). Logins only; IP locks stay at 0.';
comment on column public.sign_in_lockouts.last_locked_until is
  'M4 (2026-11-07): end of the latest lock of this key, kept after it expires so a new lock within 24 h escalates.';

-- ── Lock length per level ─────────────────────────────────────────────────
create function app.sign_in_lock_length(p_level int)
returns interval language sql immutable set search_path = '' as $$
  select least(interval '15 minutes' * power(2, greatest(least(coalesce(p_level, 0), 10), 0))::int, interval '24 hours');
$$;
comment on function app.sign_in_lock_length(int) is
  'Sign-in lockout M4 (2026-11-07): lock length for a level: 15 min × 2^level, capped at 24 h. Internal.';
revoke all on function app.sign_in_lock_length(int) from public, anon, authenticated;

-- ── account_locked alert for a login (moved out of sign_in_failed) ────────
create function app.sign_in_alert_locked(p_login text, p_locked_until timestamptz)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user  uuid;
  v_plant record;
begin
  select u.id into v_user from auth.users u
   where pg_catalog.lower(u.email) = pg_catalog.lower(pg_catalog.btrim(p_login))
   limit 1;
  if v_user is null then
    return;   -- an unknown login locks exactly like a real one, without an alert
  end if;
  for v_plant in
    select distinct p.id, p.org_id from public.memberships m
      join public.plants p on p.org_id = m.org_id and (m.plant_id is null or m.plant_id = p.id)
     where m.user_id = v_user and m.revoked_at is null
  loop
    -- Dedupe on the lock end: one alert per lock and plant, whichever RPC started the lock.
    perform app.raise_owner_alert(v_plant.org_id, v_plant.id, 'account_locked', v_user,
                                  floor(extract(epoch from p_locked_until))::bigint::text);
  end loop;
end;
$$;
comment on function app.sign_in_alert_locked(text, timestamptz) is
  'Sign-in lockout M3 (2026-11-07): writes the account_locked owner alert for every plant of the account behind a normalised login (nothing for an unknown login). dedupe_key = the lock end (epoch seconds). Internal.';
revoke all on function app.sign_in_alert_locked(text, timestamptz) from public, anon, authenticated;

-- Starts a lock on one key NOW. Logins escalate (M4) and alert (M3); IPs get the fixed length.
create function app.sign_in_start_lock(p_hash text, p_kind text, p_login text, p_now timestamptz)
returns public.sign_in_lockouts language plpgsql volatile security definer set search_path = '' as $$
declare
  v_row   public.sign_in_lockouts;
  v_lim   record;
  v_level int;
begin
  select * into v_lim from app.sign_in_limits() s where s.kind = p_kind;
  select l.* into v_row from public.sign_in_lockouts l where l.key_hash = p_hash for update;
  if v_row.key_hash is null then
    raise exception 'VALIDATION_FAILED' using detail = 'sign_in_start_lock: no counter for this key';
  end if;
  if v_row.locked_until is not null and v_row.locked_until > p_now then
    return v_row;   -- already locked: nothing new starts, no second alert
  end if;
  if p_kind = 'login' then
    v_level := case when v_row.last_locked_until is not null and v_row.last_locked_until > p_now - interval '24 hours'
                    then least(v_row.lock_level + 1, 10) else 0 end;
  else
    v_level := 0;
  end if;
  update public.sign_in_lockouts l
     set locked_until = p_now + case when p_kind = 'login' then app.sign_in_lock_length(v_level) else v_lim.lock_len end,
         last_locked_until = p_now + case when p_kind = 'login' then app.sign_in_lock_length(v_level) else v_lim.lock_len end,
         lock_level = v_level,
         attempts = v_lim.max_attempts,
         updated_at = p_now
   where l.key_hash = p_hash
  returning l.* into v_row;
  if p_kind = 'login' then
    perform app.sign_in_alert_locked(p_login, v_row.locked_until);
  end if;
  return v_row;
end;
$$;
comment on function app.sign_in_start_lock(text, text, text, timestamptz) is
  'Sign-in lockout M3/M4 (2026-11-07): the ONE place a lock starts. Login keys: length 15 min × 2^level (level + 1 when the previous lock ended less than 24 h ago, else 0; capped at 24 h) and an account_locked alert (deduped on the lock end). IP keys: the fixed 15 minutes, no alert. A key that is already locked is returned unchanged. Internal.';
revoke all on function app.sign_in_start_lock(text, text, text, timestamptz) from public, anon, authenticated;

-- ── sign_in_begin: locks start through app.sign_in_start_lock ─────────────
create or replace function public.sign_in_begin(p_login text, p_ip text default null)
returns table (allowed boolean, retry_after_seconds int)
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_now   timestamptz := pg_catalog.now();
  v_key   record;
  v_row   public.sign_in_lockouts;
  v_lim   record;
  v_retry int := 0;
begin
  perform app.check_sign_in_args(p_login, p_ip);
  -- Pass 1: refuse while a key is locked (nothing is counted).
  for v_key in select k.kind, app.sign_in_key(k.kind, k.val) as hash
                 from (values ('login', p_login), ('ip', p_ip)) k(kind, val)
                where app.sign_in_key(k.kind, k.val) is not null loop
    select l.* into v_row from public.sign_in_lockouts l where l.key_hash = v_key.hash for update;
    if v_row.locked_until is not null and v_row.locked_until > v_now then
      v_retry := greatest(v_retry, ceil(extract(epoch from v_row.locked_until - v_now))::int);
    end if;
  end loop;
  if v_retry > 0 then
    return query select false, v_retry;
    return;
  end if;
  -- Pass 2: reserve an attempt on each key (login first, then IP); a key past its limit locks now
  -- (app.sign_in_start_lock: escalation + account_locked alert for a login) and the call is refused.
  for v_key in select k.kind, app.sign_in_key(k.kind, k.val) as hash
                 from (values ('login', p_login), ('ip', p_ip)) k(kind, val)
                where app.sign_in_key(k.kind, k.val) is not null loop
    select * into v_lim from app.sign_in_limits() s where s.kind = v_key.kind;
    insert into public.sign_in_lockouts as l (key_hash, key_kind, attempts, window_started_at, locked_until, updated_at)
    values (v_key.hash, v_key.kind, 1, v_now, null, v_now)
    on conflict (key_hash) do update
      set attempts = case when l.window_started_at <= v_now - v_lim.window_len
                            or (l.locked_until is not null and l.locked_until <= v_now)
                          then 1 else l.attempts + 1 end,
          window_started_at = case when l.window_started_at <= v_now - v_lim.window_len
                                     or (l.locked_until is not null and l.locked_until <= v_now)
                                   then v_now else l.window_started_at end,
          -- An ended lock is cleared; its end stays in last_locked_until (M4 escalation memory).
          locked_until = case when l.locked_until is not null and l.locked_until <= v_now then null
                              else l.locked_until end,
          updated_at = v_now
    returning l.* into v_row;
    if v_row.attempts > v_lim.max_attempts then
      v_row := app.sign_in_start_lock(v_key.hash, v_key.kind, p_login, v_now);
      v_retry := greatest(v_retry, ceil(extract(epoch from v_row.locked_until - v_now))::int);
    end if;
  end loop;
  if v_retry > 0 then
    -- Refused. The attempt reserved on the OTHER key in this same call stays counted (L1): when the IP
    -- trips here, the login's reservation from this call is kept. Conservative: it can only lock sooner.
    return query select false, v_retry;
    return;
  end if;
  return query select true, 0;
end;
$$;
comment on function public.sign_in_begin(text, text) is
  'Sign-in lockout RPC, SERVICE ROLE only (Edge Function sign-in; 2026-11-07, hardened M3/M4): reserves one attempt for the normalised login p_login (1–254 chars) and, when given, the caller''s IP p_ip (≤ 64) before the password is checked. Returns allowed = false (and retry_after_seconds) while the login or the IP is locked, or when the reservation would pass the limit (login 5, IP 30 attempts per 15 minutes); that key is then locked through app.sign_in_start_lock (login: 15 min doubling per lock within 24 h of the previous, capped at 24 h, plus the account_locked alert; IP: 15 min). When one key trips, the other key''s reservation from the same call stays counted. Unknown logins behave exactly like real ones. Errors: VALIDATION_FAILED.';

-- ── sign_in_failed: locks start through app.sign_in_start_lock ────────────
create or replace function public.sign_in_failed(p_login text, p_ip text default null)
returns table (locked boolean, retry_after_seconds int)
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_now  timestamptz := pg_catalog.now();
  v_hash text;
  v_row  public.sign_in_lockouts;
  v_lim  record;
begin
  perform app.check_sign_in_args(p_login, p_ip);
  v_hash := app.sign_in_key('login', p_login);
  select * into v_lim from app.sign_in_limits() s where s.kind = 'login';
  select l.* into v_row from public.sign_in_lockouts l where l.key_hash = v_hash for update;
  if v_row.key_hash is null then
    -- No reservation (e.g. a success cleared it meanwhile): count this failure on its own.
    insert into public.sign_in_lockouts as l (key_hash, key_kind, attempts, window_started_at, updated_at)
    values (v_hash, 'login', 1, v_now, v_now)
    on conflict (key_hash) do update set attempts = least(l.attempts + 1, 1000), updated_at = v_now
    returning l.* into v_row;
  end if;
  if v_row.locked_until is not null and v_row.locked_until > v_now then
    -- Locked meanwhile (e.g. by a parallel sign_in_begin, which already wrote the alert).
    return query select true, ceil(extract(epoch from v_row.locked_until - v_now))::int;
    return;
  end if;
  if v_row.attempts < v_lim.max_attempts then
    update public.sign_in_lockouts l set updated_at = v_now where l.key_hash = v_hash;
    return query select false, 0;
    return;
  end if;
  v_row := app.sign_in_start_lock(v_hash, 'login', p_login, v_now);
  return query select true, ceil(extract(epoch from v_row.locked_until - v_now))::int;
end;
$$;
comment on function public.sign_in_failed(text, text) is
  'Sign-in lockout RPC, SERVICE ROLE only (Edge Function sign-in; 2026-11-07, hardened M3/M4): records a wrong password for the normalised login p_login after sign_in_begin. When the login has used its 5 attempts of the window it is locked through app.sign_in_start_lock (15 min, doubling for each new lock within 24 h of the previous one, capped at 24 h) and, if the login belongs to an account with active memberships, an account_locked owner alert is written for each of its plants (subject = the user id; dedupe_key = the lock end). Unknown logins lock exactly like real ones (no alert). Errors: VALIDATION_FAILED.';

-- ── account_locked: push by default (M4) ──────────────────────────────────
create or replace function app.alert_level_default(p_kind text)
returns text language sql immutable set search_path = '' as $$
  select case p_kind when 'customer_delivery' then 'push'
                     when 'estimate_entered' then 'quiet'
                     when 'rewash_added' then 'quiet'
                     when 'off_queue_start' then 'quiet'
                     when 'account_locked' then 'push' end;
$$;
comment on function app.alert_level_default(text) is
  'Owner 2026-11-06 (C): default level per owner alert kind: customer_delivery and account_locked (2026-11-07) push; estimate_entered, rewash_added, off_queue_start quiet; null for other kinds.';

-- ── Purge: keep the escalation memory for 24 h after the latest lock ──────
create or replace function app.purge_sign_in_lockouts()
returns int language plpgsql volatile security definer set search_path = '' as $$
declare
  v_n int;
begin
  delete from public.sign_in_lockouts l
   where l.updated_at < pg_catalog.now() - interval '1 day'
     and (l.locked_until is null or l.locked_until < pg_catalog.now())
     and (l.last_locked_until is null or l.last_locked_until < pg_catalog.now() - interval '24 hours');
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
comment on function app.purge_sign_in_lockouts() is
  'Sign-in lockout (2026-11-07): deletes counters untouched for a day that are not locked now and whose latest lock ended more than 24 h ago (the M4 escalation memory). pg_cron daily, purge-sign-in-lockouts. Returns the rows removed. Internal.';

-- ── H1 pepper: is this login an account whose password predates the pepper? ──
create function public.sign_in_account_state(p_login text)
returns table (legacy_password boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.check_sign_in_args(p_login, null);
  return query
    select coalesce(bool_or(coalesce(u.raw_app_meta_data ->> 'pw_v', '') <> '2'), false)
      from auth.users u
     where pg_catalog.lower(u.email) = pg_catalog.lower(pg_catalog.btrim(p_login));
end;
$$;
comment on function public.sign_in_account_state(text) is
  'Pepper (H1, 2026-11-07) RPC, SERVICE ROLE only (Edge Function sign-in, manage-users change_own_password): legacy_password = true when the normalised login p_login is an existing account whose stored password was not set in the peppered form (app_metadata.pw_v <> 2); false for peppered accounts and for unknown logins. Used only after a peppered password check failed, to allow ONE check of the typed form and then re-store it peppered. Errors: VALIDATION_FAILED.';
revoke all on function public.sign_in_account_state(text) from public, anon, authenticated;
grant execute on function public.sign_in_account_state(text) to service_role;
