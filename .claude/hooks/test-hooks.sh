#!/usr/bin/env bash
# Test harness for .claude/hooks guards. Usage: test-hooks.sh <repo-root>
cd "$1" || exit 1
H=.claude/hooks
fail=0
decision() { # prints allow | ask | block
  local out rc
  out=$(printf '%s' "$2" | "$H/$1" 2>/dev/null); rc=$?
  if [[ $rc -eq 2 ]]; then echo block
  elif [[ -n "$out" ]] && [[ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out")" == ask ]]; then echo ask
  else echo allow; fi
}
check() { # hook expected label json
  local got; got=$(decision "$1" "$4")
  if [[ "$got" == "$2" ]]; then printf 'ok    %-6s %s\n' "$got" "$3"; else printf 'FAIL  got=%s want=%s  %s\n' "$got" "$2" "$3"; fail=1; fi
}
bash_json() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
sql_json() { jq -nc --arg q "$1" '{tool_name:"mcp__Supabase__execute_sql",tool_input:{query:$q}}'; }

echo "== prod-guard =="
while IFS='|' read -r want c; do check prod-guard.sh "$want" "$c" "$(bash_json "$c")"; done <<'EOF'
allow|git push -u origin claude/ecstatic-turing-kfxe47
allow|git push origin claude/maintenance
ask|git push origin main
ask|git push origin HEAD:main
ask|git push origin "main"
ask|git -C . push origin main
ask|git push --mirror
ask|git push origin +feature
ask|git push -fu origin feature
ask|git push --force-with-lease origin feature
ask|gh pr merge 2
ask|npx supabase db reset --linked
ask|npx supabase migration up --linked
ask|supabase --debug db push
ask|echo RELEASE_APPROVED=1; supabase db push
ask|npx supabase config push
ask|supabase functions deploy invite-user
allow|npx supabase db reset
allow|npx supabase test db
allow|npm run db:reset
EOF
check prod-guard.sh ask "MCP apply_migration" '{"tool_name":"mcp__Supabase__apply_migration","tool_input":{}}'
check prod-guard.sh ask "MCP execute_sql" '{"tool_name":"mcp__Supabase__execute_sql","tool_input":{"query":"select 1"}}'
check prod-guard.sh allow "MCP list_tables" '{"tool_name":"mcp__Supabase__list_tables","tool_input":{}}'

echo "== readonly-sql =="
check readonly-sql.sh allow "select" "$(sql_json 'select * from plants;')"
check readonly-sql.sh allow "with ... select" "$(sql_json 'with x as (select 1) select * from x')"
check readonly-sql.sh block "two statements" "$(sql_json 'select 1; delete from plants')"
check readonly-sql.sh block "select into" "$(sql_json 'select * into t from plants')"
check readonly-sql.sh block "cron.schedule" "$(sql_json 'select cron.schedule(1)')"
check readonly-sql.sh block "app rpc call" "$(sql_json 'select app.move_queue_item(1)')"
check readonly-sql.sh block "update" "$(sql_json 'update plants set name = 1')"
check readonly-sql.sh block "psql -f" "$(bash_json 'psql -f x.sql')"
check readonly-sql.sh block "psql < file" "$(bash_json 'psql < x.sql')"
check readonly-sql.sh allow "psql -c select" "$(bash_json 'psql -c "select 1"')"
check readonly-sql.sh block "psql -c update" "$(bash_json 'psql -c "update plants set name=1"')"
check readonly-sql.sh allow "supabase test db" "$(bash_json 'npx supabase test db')"
check readonly-sql.sh block "supabase db reset" "$(bash_json 'npx supabase db reset')"
check readonly-sql.sh allow "grep for create policy" "$(bash_json 'grep -rn "create policy" supabase/')"
exit $fail
