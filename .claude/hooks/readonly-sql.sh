#!/usr/bin/env bash
# PreToolUse guard for read-only agents. Allows exactly one SELECT / WITH / EXPLAIN
# statement and blocks file-fed SQL. Residual risk: a SELECT can still call a function
# with side effects, so reviewer prompts forbid calling app.* RPCs.
input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")
block() { echo "Blocked: read-only agent. $1" >&2; exit 2; }

if [[ "$tool" == mcp__*execute_sql ]]; then
  sql=$(jq -r '.tool_input.query // empty' <<<"$input")
else
  cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
  # Only commands that invoke a database client (as a command word, not inside a path).
  grep -qiE '(^|[;&|[:space:]])(psql|pg_restore|pg_dump|supabase)([[:space:]]|$)' <<<"$cmd" || exit 0
  grep -qiE 'supabase +test +db *($|[;&|])' <<<"$cmd" && exit 0
  grep -qiE '(^|[;&|[:space:]])supabase([[:space:]]|$)' <<<"$cmd" && block "Only 'supabase test db' is allowed."
  grep -qE '(^|[[:space:]])(-f|--file)([[:space:]=]|$)|\\i|<' <<<"$cmd" && block "No SQL from files or stdin."
  # Read the SQL passed to psql -c/--command (single or double quoted).
  sql=$(grep -oE "(-c|--command)[ =]+(\"[^\"]*\"|'[^']*')" <<<"$cmd" | sed -E "s/^(-c|--command)[ =]+//; s/^[\"']//; s/[\"']$//")
  [[ -z "$sql" ]] && block "Use psql -c with a single SELECT."
fi

body=$(printf '%s' "$sql" | sed -E 's/--.*$//' | tr '\n' ' ' | sed -E 's/;[[:space:]]*$//')
grep -q ';' <<<"$body" && block "One statement only."
grep -qiE '^[[:space:]]*(select|with|explain)\b' <<<"$body" || block "Only SELECT/WITH/EXPLAIN."
side_effects='\b(insert|update|delete|drop|alter|create|truncate|grant|revoke|comment|copy|merge|call|do|into|set_config|pg_terminate_backend|pg_cancel_backend|lo_import|lo_export)\b|\b(cron|net|app)\.'
grep -qiE "$side_effects" <<<"$body" && block "Write or side-effect keyword found."
exit 0
