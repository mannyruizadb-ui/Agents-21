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
