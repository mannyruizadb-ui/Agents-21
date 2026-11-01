# security-reviewer memory
## 2026-10-30 Sprint Zero review (PR #2) -> PASS WITH NOTES
- Cloud project ypurifebjiivvltbcufx: empty, advisors clean. config.toml auth does NOT apply to cloud; verify dashboard signup=off + redirect allow-list before first db push.
- GitHub main branch unprotected (gh api 404). Hooks are the only guard.
- prod-guard.sh bypasses confirmed by running the hook: HEAD:main&&, quoted "main", git -C, +refspec, -fu, --mirror, gh pr merge, db reset --linked, migration up --linked, config push, functions deploy, flags before "db push", RELEASE_APPROVED=1 anywhere.
- No hook on MCP apply_migration/execute_sql for db-engineer (full Supabase MCP on the only cloud project).
- readonly-sql.sh: psql -f file and SELECT-with-side-effects bypass; Bash can write files despite memory-only hook.
- RLS guard covers public r/p only; not views (security_invoker), matviews, foreign tables, or other exposed schemas.
- To re-check at M1: §4.7 matrix pgTAP per role, security definer search_path, views security_invoker.
- 2026-10-30 (meta, after review): prod-guard.sh rewritten to "ask" (no RELEASE_APPROVED token, loose matching, covers MCP Supabase writes); readonly-sql.sh single-statement SELECT only, blocks -f/\i/stdin/cron./net./app.; RLS guard extended (views, matviews/foreign, secdef search_path). Hook tests in .claude/hooks/test-hooks.sh run in CI. Still open: GitHub ruleset on main (owner), cloud auth signup=off (owner), Bash writes by reviewers (residual).
## 2026-11-01 M1 part 1 DB foundation review (uncommitted, branch claude/ecstatic-turing-kfxe47) -> BLOCK (2 small isolation fixes)
- Verified OK: all app/public fn ACLs minimal (pg_proc dump); global `alter default privileges for role postgres revoke execute on functions from public` works; extensions owned by supabase_admin so unaffected; views security_invoker; RLS on all 26 tables; pin_hash/counters column-grant protected; lockout persists (D4); pairing code uses gen_random_bytes %32; 315/315 pgTAP pass.
- BLOCK items: devices.user_id unconstrained on client INSERT/UPDATE (manager of org A can bind any auth user incl. other tenant; pairing_codes C/U lets manager bypass 15-min/single-use); SECURITY DEFINER BEFORE triggers (check_languages, check_estimate_unit, apply_count_mode, throttle_writes) raise before RLS WITH CHECK -> cross-tenant config oracle given UUIDs.
- Notes: audit_log keeps failed_pin_attempts/locked_until; TRUNCATE still granted on append-only tables; anon gets EXECUTE by default on new public fns (per-schema default); fixtures lack 2nd plant in org A; fge insert allows voided_at/voided_by; app_events.device_id any tenant.
- Re-check at M1 part 2: pair-device (JWT->membership before service client, IP+global rate limit, atomic consume where consumed_at is null and expires_at>now()), staff_sessions bound to auth_user_id/plant/expiry/consumed in M2 write RPCs, on-conflict(client_id) return must filter by plant, import storage_path prefix check.
