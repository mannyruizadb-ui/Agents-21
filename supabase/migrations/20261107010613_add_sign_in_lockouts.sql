-- Sign-in lockout (owner-approved 2026-11-06: 6-digit passwords for managers, with lockout).
--
-- Supabase Pro has no password-verification hook, so the lockout is ours: the Edge Function `sign-in`
-- (service role) asks this table before it calls GoTrue's password grant, and reports the outcome after.
--
-- * public.sign_in_lockouts: one row per KEY, keyed by a SHA-256 hash of the normalised login
--   ('login:<email>') or of the caller's IP ('ip:<address>'), never by user id, so unknown usernames
--   behave exactly like real ones (no oracle) and typed values (sometimes a password typed into the
--   username box) are never stored in clear. No org_id / plant_id: a login is global (auth.users) and an
--   unknown one has no tenant. RLS on, no policies, no grants to anon / authenticated: service role only.
--   Ephemeral security state, not operational history: rows are cleared on success and purged daily.
-- * Rules (constants in app.sign_in_limits()):
--     login: 5 attempts per 15-minute window; the 5th FAILURE locks the login for 15 minutes.
--     ip:    30 attempts per 15-minute window (successes are given back), then 15 minutes locked.
--   Attempts are RESERVED before GoTrue is called (sign_in_begin), so a burst of parallel requests can
--   never make more than 5 guesses per window; a success clears the login row (sign_in_succeeded).
-- * When a login becomes locked and it belongs to an account with memberships, an `account_locked` owner
--   alert is written for every plant of the account (owner information kind, default level quiet,
--   owners only, never managers). Payload: user_id, username (only for <u>@accounts.adbheadquarters.com
--   accounts; null otherwise, never an email), failures, locked_until, still_locked.
-- * Service-role RPCs: sign_in_begin, sign_in_failed, sign_in_succeeded (sign-in); sign_in_unlock and
--   sign_in_lock_status (manage-users: unlock, list), after manage-users' own owner check.

-- ── Limits and keys ───────────────────────────────────────────────────────
create function app.sign_in_limits()
returns table (kind text, max_attempts int, window_len interval, lock_len interval)
language sql immutable set search_path = '' as $$
  values ('login', 5, interval '15 minutes', interval '15 minutes'),
         ('ip', 30, interval '15 minutes', interval '15 minutes');
$$;
comment on function app.sign_in_limits() is
  'Sign-in lockout (2026-11-07): per key kind, attempts allowed per window, the window and the lock length. login: 5 / 15 min / 15 min; ip: 30 / 15 min / 15 min. Internal.';
revoke all on function app.sign_in_limits() from public, anon, authenticated;

-- 'login:<lower(trim(login))>' or 'ip:<trim(ip)>' → hex SHA-256. Null for an empty value.
create function app.sign_in_key(p_kind text, p_value text)
returns text language sql immutable set search_path = '' as $$
  select case when p_kind in ('login', 'ip') and pg_catalog.btrim(coalesce(p_value, '')) <> ''
              then pg_catalog.encode(extensions.digest(
                     p_kind || ':' || case p_kind when 'login' then pg_catalog.lower(pg_catalog.btrim(p_value))
                                                  else pg_catalog.btrim(p_value) end, 'sha256'), 'hex') end;
$$;
comment on function app.sign_in_key(text, text) is
  'Sign-in lockout (2026-11-07): the table key for a login (normalised: trimmed, lowercased) or an IP: hex SHA-256 of ''<kind>:<value>''. Internal.';
revoke all on function app.sign_in_key(text, text) from public, anon, authenticated;

-- ── Table ─────────────────────────────────────────────────────────────────
create table public.sign_in_lockouts (
  key_hash          text primary key check (key_hash ~ '^[0-9a-f]{64}$'),
  key_kind          text not null check (key_kind in ('login', 'ip')),
  attempts          int not null default 0 check (attempts between 0 and 1000),
  window_started_at timestamptz not null default now(),
  locked_until      timestamptz,
  updated_at        timestamptz not null default now()
);
alter table public.sign_in_lockouts enable row level security;
create index sign_in_lockouts_updated_idx on public.sign_in_lockouts (updated_at);
comment on table public.sign_in_lockouts is
  'Sign-in lockout (owner-approved 2026-11-06, built 2026-11-07): attempt counters and locks per SHA-256 key of a normalised login or an IP (never a user id; unknown logins behave like real ones). Service role only (the sign-in and manage-users Edge Functions via the sign_in_* RPCs): RLS on, no policies, no client grants. Ephemeral: cleared on success, purged daily by app.purge_sign_in_lockouts().';
revoke all on public.sign_in_lockouts from anon, authenticated;

-- ── account_locked: a new owner information alert kind ────────────────────
alter table public.alert_events
  drop constraint alert_events_kind_check,
  add constraint alert_events_kind_check check (kind in ('estimate_stale', 'device_offline', 'import_failed',
    'shift_generation_failed', 'machine_down', 'washer_idle', 'task_assigned', 'task_done', 'route_loaded',
    'customer_delivery', 'estimate_entered', 'rewash_added', 'off_queue_start', 'account_locked'));

create or replace function app.owner_alert_kinds()
returns text[] language sql immutable set search_path = '' as $$
  select array['customer_delivery', 'estimate_entered', 'rewash_added', 'off_queue_start', 'account_locked'];
$$;
comment on function app.owner_alert_kinds() is
  'Owner 2026-11-06 (C): the owner information alert kinds that have a per-owner level (push | quiet | off). account_locked added 2026-11-07.';

create or replace function app.alert_level_default(p_kind text)
returns text language sql immutable set search_path = '' as $$
  select case p_kind when 'customer_delivery' then 'push'
                     when 'estimate_entered' then 'quiet'
                     when 'rewash_added' then 'quiet'
                     when 'off_queue_start' then 'quiet'
                     when 'account_locked' then 'quiet' end;
$$;
comment on function app.alert_level_default(text) is
  'Owner 2026-11-06 (C): default level per owner alert kind: customer_delivery push; estimate_entered, rewash_added, off_queue_start, account_locked quiet; null for other kinds.';

alter table public.memberships
  drop constraint memberships_alert_levels_ok,
  add constraint memberships_alert_levels_ok check (
    jsonb_typeof(alert_levels) = 'object'
    and (alert_levels - '{customer_delivery,estimate_entered,rewash_added,off_queue_start,account_locked}'::text[]) = '{}'::jsonb
    and not jsonb_path_exists(alert_levels, '$.* ? (@.type() != "string" || (@ != "push" && @ != "quiet" && @ != "off"))'));

create or replace function app.push_alert_kinds()
returns text[] language sql immutable set search_path = '' as $$
  select array['machine_down', 'washer_idle', 'task_assigned', 'task_done', 'route_loaded',
               'customer_delivery', 'estimate_entered', 'rewash_added', 'off_queue_start', 'account_locked'];
$$;
comment on function app.push_alert_kinds() is
  'Owner 2026-11-06: alert_events kinds shown in the Alerts tab and delivered by Web Push to their push recipients (owner information kinds, account_locked included, only to owners whose level is push).';

create or replace function public.set_alert_level(p_membership_id uuid, p_kind text, p_level text)
returns public.memberships language plpgsql volatile security definer set search_path = '' as $$
declare
  v public.memberships;
begin
  -- Role check FIRST: the caller must be an owner of the membership's plant (or of its org for an
  -- org-wide membership). Missing and foreign ids give the same NOT_AUTHORIZED.
  select m.* into v from public.memberships m where m.id = p_membership_id;
  if v.id is null
     or not (case when v.plant_id is null then app.has_org_role(v.org_id, '{owner}')
                  else app.has_role(v.plant_id, '{owner}') end) then
    raise exception 'NOT_AUTHORIZED' using detail = 'set_alert_level requires owner of the membership''s plant';
  end if;
  if p_kind is null or not (p_kind = any (app.owner_alert_kinds())) then
    raise exception 'VALIDATION_FAILED' using detail = 'p_kind: customer_delivery, estimate_entered, rewash_added, off_queue_start or account_locked';
  end if;
  if p_level is null or p_level not in ('push', 'quiet', 'off') then
    raise exception 'VALIDATION_FAILED' using detail = 'p_level: push, quiet or off';
  end if;
  if v.revoked_at is not null then
    raise exception 'VALIDATION_FAILED' using detail = 'membership: revoked';
  end if;
  if v.role <> 'owner' then
    raise exception 'VALIDATION_FAILED' using detail = 'only owner memberships have alert levels';
  end if;
  update public.memberships m
     set alert_levels = m.alert_levels || pg_catalog.jsonb_build_object(p_kind, p_level)
   where m.id = v.id
  returning m.* into v;
  return v;
end;
$$;
comment on function public.set_alert_level(uuid, text, text) is
  'Owner 2026-11-06 RPC (owner of the membership''s plant, or of the org for an org-wide membership; definer, role check first, no oracle): sets one OWNER membership''s level for an owner information alert kind (customer_delivery | estimate_entered | rewash_added | off_queue_start | account_locked) to push (push + Alerts tab), quiet (Alerts tab and badge, no push) or off (hidden). Same targeting rule as set_washer_idle_alert. Returns the memberships row (alert_levels). Errors: NOT_AUTHORIZED, VALIDATION_FAILED.';

-- The username shown for an account: the <u> of <u>@accounts.adbheadquarters.com, else null (an
-- owner's own email is never shown). Mirrors supabase/functions/_shared/loginId.ts usernameFromEmail.
create function app.login_username(p_email text)
returns text language sql immutable set search_path = '' as $$
  select case when pg_catalog.lower(p_email) ~ '^[a-z0-9._-]{3,32}@accounts\.adbheadquarters\.com$'
              then pg_catalog.split_part(pg_catalog.lower(p_email), '@', 1) end;
$$;
comment on function app.login_username(text) is
  'Sign-in (2026-11-07): the username of a mapped login email (<u>@accounts.adbheadquarters.com, u = a-z 0-9 . _ -, 3–32), else null. Same rule as usernameFromEmail in supabase/functions/_shared/loginId.ts. Internal.';
revoke all on function app.login_username(text) from public, anon, authenticated;

-- ── RPCs (service role only) ──────────────────────────────────────────────
create function app.check_sign_in_args(p_login text, p_ip text)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if p_login is null or pg_catalog.char_length(pg_catalog.btrim(p_login)) not between 1 and 254 then
    raise exception 'VALIDATION_FAILED' using detail = 'p_login: 1–254 characters';
  end if;
  if p_ip is not null and pg_catalog.char_length(p_ip) > 64 then
    raise exception 'VALIDATION_FAILED' using detail = 'p_ip: at most 64 characters';
  end if;
end;
$$;
comment on function app.check_sign_in_args(text, text) is
  'Sign-in lockout (2026-11-07): argument checks shared by the sign_in_* RPCs. Internal.';
revoke all on function app.check_sign_in_args(text, text) from public, anon, authenticated;

-- Reserves one attempt for the login and the IP. allowed = false while either is locked or out of
-- attempts for the window; retry_after_seconds then says how long (the longer of the two).
create function public.sign_in_begin(p_login text, p_ip text default null)
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
  -- Pass 2: reserve an attempt on each key; a key past its limit locks now and refuses.
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
          locked_until = case when l.locked_until is not null and l.locked_until <= v_now then null
                              else l.locked_until end,
          updated_at = v_now
    returning l.* into v_row;
    if v_row.attempts > v_lim.max_attempts then
      update public.sign_in_lockouts l
         set locked_until = v_now + v_lim.lock_len, attempts = v_lim.max_attempts
       where l.key_hash = v_key.hash
      returning l.* into v_row;
      v_retry := greatest(v_retry, ceil(extract(epoch from v_row.locked_until - v_now))::int);
    end if;
  end loop;
  if v_retry > 0 then
    -- The refused attempt is not an attempt: nothing else changes (the lock was just set above).
    return query select false, v_retry;
    return;
  end if;
  return query select true, 0;
end;
$$;
comment on function public.sign_in_begin(text, text) is
  'Sign-in lockout (2026-11-07) RPC, SERVICE ROLE only (Edge Function sign-in): reserves one attempt for the normalised login p_login (1–254 chars) and the caller''s IP p_ip (optional, ≤ 64) before the password is checked. Returns allowed = false (and retry_after_seconds) while the login or the IP is locked, or when the reservation would pass the limit (login 5, IP 30 attempts per 15 minutes; that key is then locked for 15 minutes). Unknown logins behave exactly like real ones. Errors: VALIDATION_FAILED.';
revoke all on function public.sign_in_begin(text, text) from public, anon, authenticated;
grant execute on function public.sign_in_begin(text, text) to service_role;

-- The password was wrong (or the account cannot sign in). The reserved attempt stays counted; when the
-- login has used all its attempts in the window it is locked now and the owners are told.
create function public.sign_in_failed(p_login text, p_ip text default null)
returns table (locked boolean, retry_after_seconds int)
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_now   timestamptz := pg_catalog.now();
  v_hash  text;
  v_row   public.sign_in_lockouts;
  v_lim   record;
  v_user  record;
  v_plant record;
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
    return query select true, ceil(extract(epoch from v_row.locked_until - v_now))::int;
    return;
  end if;
  if v_row.attempts < v_lim.max_attempts then
    update public.sign_in_lockouts l set updated_at = v_now where l.key_hash = v_hash;
    return query select false, 0;
    return;
  end if;
  update public.sign_in_lockouts l
     set locked_until = v_now + v_lim.lock_len, updated_at = v_now
   where l.key_hash = v_hash
  returning l.* into v_row;

  -- Tell the owners of every plant of the account (if the login is a real account with access).
  select u.id, u.email into v_user from auth.users u
   where pg_catalog.lower(u.email) = pg_catalog.lower(pg_catalog.btrim(p_login))
   limit 1;
  if v_user.id is not null then
    for v_plant in
      select distinct p.id, p.org_id from public.memberships m
        join public.plants p on p.org_id = m.org_id and (m.plant_id is null or m.plant_id = p.id)
       where m.user_id = v_user.id and m.revoked_at is null
    loop
      perform app.raise_owner_alert(v_plant.org_id, v_plant.id, 'account_locked', v_user.id,
                                    extract(epoch from v_row.locked_until)::bigint::text);
    end loop;
  end if;
  return query select true, ceil(extract(epoch from v_row.locked_until - v_now))::int;
end;
$$;
comment on function public.sign_in_failed(text, text) is
  'Sign-in lockout (2026-11-07) RPC, SERVICE ROLE only (Edge Function sign-in): records a wrong password for the normalised login p_login after sign_in_begin. When the login has used its 5 attempts of the window it is locked for 15 minutes (locked = true, retry_after_seconds) and, if the login belongs to an account with active memberships, an account_locked owner alert is written for each of its plants (subject = the user id; dedupe_key = the lock end, epoch seconds). Unknown logins lock exactly like real ones (no alert). Errors: VALIDATION_FAILED.';
revoke all on function public.sign_in_failed(text, text) from public, anon, authenticated;
grant execute on function public.sign_in_failed(text, text) to service_role;

-- The password was right: the login starts fresh, and the IP gets its reserved attempt back.
create function public.sign_in_succeeded(p_login text, p_ip text default null)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  perform app.check_sign_in_args(p_login, p_ip);
  delete from public.sign_in_lockouts l where l.key_hash = app.sign_in_key('login', p_login);
  update public.sign_in_lockouts l
     set attempts = greatest(l.attempts - 1, 0), updated_at = pg_catalog.now()
   where l.key_hash = app.sign_in_key('ip', p_ip) and l.locked_until is null;
end;
$$;
comment on function public.sign_in_succeeded(text, text) is
  'Sign-in lockout (2026-11-07) RPC, SERVICE ROLE only (Edge Function sign-in): a correct password clears the login''s counter and gives the IP its reserved attempt back (unless the IP is locked). Errors: VALIDATION_FAILED.';
revoke all on function public.sign_in_succeeded(text, text) from public, anon, authenticated;
grant execute on function public.sign_in_succeeded(text, text) to service_role;

-- An owner unlocks a person (manage-users `unlock`, after its own owner check).
create function public.sign_in_unlock(p_login text)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
declare
  v_n int;
begin
  perform app.check_sign_in_args(p_login, null);
  delete from public.sign_in_lockouts l where l.key_hash = app.sign_in_key('login', p_login);
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;
comment on function public.sign_in_unlock(text) is
  'Sign-in lockout (2026-11-07) RPC, SERVICE ROLE only (Edge Function manage-users `unlock`, after its owner check): clears the lock and the counter of a normalised login. Returns true when there was something to clear. Errors: VALIDATION_FAILED.';
revoke all on function public.sign_in_unlock(text) from public, anon, authenticated;
grant execute on function public.sign_in_unlock(text) to service_role;

-- Lock state of up to 500 logins (manage-users `list`).
create function public.sign_in_lock_status(p_logins text[])
returns table (login text, locked_until timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_logins is null or pg_catalog.cardinality(p_logins) > 500 then
    raise exception 'VALIDATION_FAILED' using detail = 'p_logins: at most 500';
  end if;
  return query
    select x.login, l.locked_until
      from pg_catalog.unnest(p_logins) x(login)
      join public.sign_in_lockouts l on l.key_hash = app.sign_in_key('login', x.login)
     where l.locked_until > pg_catalog.now();
end;
$$;
comment on function public.sign_in_lock_status(text[]) is
  'Sign-in lockout (2026-11-07) RPC, SERVICE ROLE only (Edge Function manage-users `list`): for the given normalised logins (≤ 500), the ones locked now and until when. Errors: VALIDATION_FAILED.';
revoke all on function public.sign_in_lock_status(text[]) from public, anon, authenticated;
grant execute on function public.sign_in_lock_status(text[]) to service_role;

-- ── Daily purge (ephemeral state) ─────────────────────────────────────────
create function app.purge_sign_in_lockouts()
returns int language plpgsql volatile security definer set search_path = '' as $$
declare
  v_n int;
begin
  delete from public.sign_in_lockouts l
   where l.updated_at < pg_catalog.now() - interval '1 day'
     and (l.locked_until is null or l.locked_until < pg_catalog.now());
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
comment on function app.purge_sign_in_lockouts() is
  'Sign-in lockout (2026-11-07): deletes counters untouched for a day that are not locked now (pg_cron daily, purge-sign-in-lockouts). Returns the rows removed. Internal.';
revoke all on function app.purge_sign_in_lockouts() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'purge-sign-in-lockouts';
    perform cron.schedule('purge-sign-in-lockouts', '41 4 * * *', 'select app.purge_sign_in_lockouts()');
  else
    raise warning 'pg_cron is not available: schedule app.purge_sign_in_lockouts() manually';
  end if;
end;
$$;

-- ── alert_payload: + account_locked ───────────────────────────────────────
-- Same as 20261107010316 plus the account_locked branch (only that branch is new).
create or replace function app.alert_payload(p_alert public.alert_events)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v jsonb;
begin
  if p_alert.kind = 'machine_down' then
    select pg_catalog.jsonb_build_object(
             'machine_id', m.id, 'machine_name', m.name, 'machine_kind', m.kind, 'area_name', ar.name,
             'reason_code', e.reason_code, 'reason_label_i18n', r.label_i18n, 'down_since', e.occurred_at,
             'still_down', app.machine_is_down_at(m.id, m.plant_id, pg_catalog.now()))
      into v
      from public.machine_status_events e
      join public.machines m on m.id = e.machine_id and m.plant_id = e.plant_id
      join public.areas ar on ar.id = m.area_id and ar.plant_id = m.plant_id
      left join public.machine_down_reasons r on r.plant_id = e.plant_id and r.code = e.reason_code
     where e.id = p_alert.subject_id and e.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'washer_idle' then
    select pg_catalog.jsonb_build_object(
             'machine_id', m.id, 'machine_name', m.name, 'area_name', ar.name,
             'idle_since', greatest(c.started_at + pg_catalog.make_interval(mins => f.cycle_minutes),
                                    (select max(si.starts_at) from public.shift_instances si
                                      where si.area_id = m.area_id and si.plant_id = m.plant_id and si.skipped_at is null
                                        and si.starts_at <= p_alert.sent_at and si.ends_at > p_alert.sent_at)),
             'still_idle', not exists (select 1 from public.washer_cycles w2
                                        where w2.machine_id = m.id and w2.plant_id = m.plant_id and w2.voided_at is null
                                          and (w2.started_at, w2.id) > (c.started_at, c.id)))
      into v
      from public.machines m
      join public.areas ar on ar.id = m.area_id and ar.plant_id = m.plant_id
      left join public.washer_cycles c on c.id::text = p_alert.dedupe_key and c.plant_id = m.plant_id
      left join public.wash_formulas f on f.id = c.wash_formula_id
     where m.id = p_alert.subject_id and m.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'route_loaded' then
    select pg_catalog.jsonb_build_object(
             'route_id', r.id, 'route_name', r.name, 'load_time', r.load_time, 'load_date', e.load_date,
             'loaded_at', e.occurred_at)
      into v
      from public.route_load_events e
      join public.routes r on r.id = e.route_id and r.plant_id = e.plant_id
     where e.id = p_alert.subject_id and e.plant_id = p_alert.plant_id;
  elsif p_alert.kind in ('task_assigned', 'task_done') then
    -- The task's own text goes to its assignees (task_assigned) and back to the owners (task_done).
    -- The done note and any names never go in a payload.
    select pg_catalog.jsonb_build_object(
             'task_id', t.id, 'body', t.body, 'to_on_duty', t.to_on_duty, 'created_at', t.created_at,
             'reminder', case when p_alert.kind = 'task_assigned' then coalesce(p_alert.dedupe_key, '0')::int end,
             'done_at', t.done_at, 'reviewed_at', t.reviewed_at)
      into v
      from public.tasks t
     where t.id = p_alert.subject_id and t.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'customer_delivery' then
    -- Owner 2026-11-06: customer, when, and per line the group + bins (+ loads); no names, no note.
    select pg_catalog.jsonb_build_object(
             'delivery_id', d.id, 'customer_id', c.id, 'customer_name', c.name, 'customer_name_i18n', c.name_i18n,
             'delivered_at', d.delivered_at, 'voided', d.voided_at is not null,
             'total_bins', (select sum(l.bins) from public.customer_delivery_lines l
                             where l.delivery_id = d.id and l.plant_id = d.plant_id),
             'lines', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                                  'wash_group_id', g.id, 'wash_group_name', g.name, 'wash_group_name_i18n', g.name_i18n,
                                  'bins', l.bins, 'loads', l.loads) order by l.line_no)
                                  from public.customer_delivery_lines l
                                  join public.wash_groups g on g.id = l.wash_group_id and g.plant_id = l.plant_id
                                 where l.delivery_id = d.id and l.plant_id = d.plant_id), '[]'::jsonb))
      into v
      from public.customer_deliveries d
      join public.customers c on c.id = d.customer_id and c.plant_id = d.plant_id
     where d.id = p_alert.subject_id and d.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'estimate_entered' then
    -- The batch: estimates the same account recorded on the plant within 10 minutes of the FIRST one (the
    -- alert's subject; its recorded_at, else the alert's sent_at for rows from before recorded_at). The
    -- account is only used to group; it is never in the payload.
    select pg_catalog.jsonb_build_object(
             'first_estimate_id', f.id,
             'count', (select count(*) from public.soil_estimates e
                        where e.plant_id = f.plant_id and e.entered_by = f.entered_by
                          and e.recorded_at >= coalesce(f.recorded_at, p_alert.sent_at)
                          and e.recorded_at < coalesce(f.recorded_at, p_alert.sent_at) + interval '10 minutes'),
             'estimates', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                                      'estimate_id', e.id, 'wash_group_id', g.id, 'wash_group_name', g.name,
                                      'wash_group_name_i18n', g.name_i18n, 'customer_id', g.customer_id,
                                      'qty', e.qty, 'unit', e.unit,
                                      'qty_loads', app.to_loads(e.wash_group_id, null, e.qty, e.unit),
                                      'entered_at', e.entered_at) order by e.recorded_at, e.id)
                                      from public.soil_estimates e
                                      join public.wash_groups g on g.id = e.wash_group_id and g.plant_id = e.plant_id
                                     where e.plant_id = f.plant_id and e.entered_by = f.entered_by
                                       and e.recorded_at >= coalesce(f.recorded_at, p_alert.sent_at)
                                       and e.recorded_at < coalesce(f.recorded_at, p_alert.sent_at) + interval '10 minutes'), '[]'::jsonb))
      into v
      from public.soil_estimates f
     where f.id = p_alert.subject_id and f.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'rewash_added' then
    select pg_catalog.jsonb_build_object(
             'queue_item_id', q.id, 'area_id', ar.id, 'area_name', ar.name,
             'wash_group_id', g.id, 'wash_group_name', g.name, 'wash_group_name_i18n', g.name_i18n,
             'customer_id', q.customer_id, 'qty', q.qty, 'unit', q.unit,
             'qty_loads', app.to_loads(q.wash_group_id, q.item_type_id, q.qty, q.unit),
             'status', q.status, 'created_at', q.created_at)
      into v
      from public.queue_items q
      join public.areas ar on ar.id = q.area_id and ar.plant_id = q.plant_id
      join public.wash_groups g on g.id = q.wash_group_id and g.plant_id = q.plant_id
     where q.id = p_alert.subject_id and q.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'off_queue_start' then
    select pg_catalog.jsonb_build_object(
             'cycle_id', w.id, 'machine_id', m.id, 'machine_name', m.name, 'area_name', ar.name,
             'wash_group_id', g.id, 'wash_group_name', g.name, 'wash_group_name_i18n', g.name_i18n,
             'customer_id', w.customer_id, 'is_rewash', w.is_rewash, 'started_at', w.started_at,
             'queue_item_id', w.queue_item_id, 'off_queue', w.queue_item_id is null,
             'expected_wash_group_id', xg.id, 'expected_wash_group_name', xg.name,
             'expected_wash_group_name_i18n', xg.name_i18n,
             'voided', w.voided_at is not null)
      into v
      from public.washer_cycles w
      join public.machines m on m.id = w.machine_id and m.plant_id = w.plant_id
      join public.areas ar on ar.id = w.area_id and ar.plant_id = w.plant_id
      left join public.wash_groups g on g.id = w.wash_group_id and g.plant_id = w.plant_id
      left join public.wash_groups xg on xg.id::text = p_alert.dedupe_key and xg.plant_id = w.plant_id
     where w.id = p_alert.subject_id and w.plant_id = p_alert.plant_id;
  elsif p_alert.kind = 'account_locked' then
    -- 2026-11-07: a security event for owners. The username IS the subject (mapped accounts only; an
    -- owner's own email is never shown). No IP, no typed values, no password detail.
    select pg_catalog.jsonb_build_object(
             'user_id', u.id, 'username', app.login_username(u.email),
             'failures', (select s.max_attempts from app.sign_in_limits() s where s.kind = 'login'),
             'locked_until', pg_catalog.to_timestamp(p_alert.dedupe_key::bigint),
             'still_locked', exists (select 1 from public.sign_in_lockouts l
                                      where l.key_hash = app.sign_in_key('login', u.email)
                                        and l.locked_until > pg_catalog.now()))
      into v
      from auth.users u
     where u.id = p_alert.subject_id and p_alert.dedupe_key ~ '^[0-9]{1,12}$';
  end if;
  return coalesce(v, '{}'::jsonb);
end;
$function$;
comment on function app.alert_payload(public.alert_events) is
  'Owner 2026-11-06: what an alert may show, per kind (jsonb; no free text except a task''s own text to its assignees/owners; never names or notes, except account_locked''s username for owners). machine_down: machine, area, reason_code + label, down_since, still_down. washer_idle: machine, area, idle_since, still_idle. route_loaded: route, load_time, load_date, loaded_at. task_assigned / task_done: task_id, body, to_on_duty, created_at, reminder, done_at, reviewed_at. customer_delivery: delivery_id, customer, delivered_at, voided, total_bins, lines[group, bins, loads]. estimate_entered: first_estimate_id, count, estimates[group, customer_id, qty, unit, qty_loads, entered_at] (the batch window starts at the first estimate''s recorded_at). rewash_added: queue item, area, group, customer_id, qty, unit, qty_loads, status, created_at. off_queue_start: cycle, machine, area, group, customer_id, is_rewash, started_at, queue_item_id, off_queue, expected group, voided. account_locked (2026-11-07): user_id, username (mapped accounts only, else null), failures, locked_until, still_locked. Internal.';
