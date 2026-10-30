#!/usr/bin/env bash
# PreToolUse guard for read-only agents: block SQL that writes, whether sent through the
# Supabase MCP execute_sql tool or a psql/supabase CLI command. Exit 2 = block.
input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")
if [[ "$tool" == mcp__*execute_sql ]]; then
  sql=$(jq -r '.tool_input.query // empty' <<<"$input")
else
  cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
  # Only inspect commands that reach a database; plain greps of SQL files stay allowed.
  if ! grep -qiE '(^|[;&| ])(psql|pg_restore|supabase +(db|migration|seed))' <<<"$cmd"; then exit 0; fi
  if grep -qiE 'supabase +(db +(reset|push|start)|migration +(up|repair|new))' <<<"$cmd"; then
    echo "Blocked: read-only agent cannot change database state." >&2; exit 2
  fi
  sql=$cmd
fi
if grep -qiE '\b(insert|update|delete|drop|alter|create|truncate|grant|revoke|comment|copy|merge|call|do)\b' <<<"$sql"; then
  echo "Blocked: read-only agent may run SELECT queries only." >&2
  exit 2
fi
exit 0
