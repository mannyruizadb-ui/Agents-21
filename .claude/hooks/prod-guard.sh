#!/usr/bin/env bash
# PreToolUse guard (all agents). Production- or history-affecting actions always go to a
# human: we answer "ask" so Claude Code prompts the owner. There is deliberately no
# self-declared bypass flag. Server-side protection (GitHub ruleset on main) is the real
# control; this hook is the early warning.
input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")

ask() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask",
    permissionDecisionReason: ("Needs the owner approval: " + $r + " (CLAUDE.md: Never do without explicit approval).")}}'
  exit 0
}

case "$tool" in
  mcp__Supabase__apply_migration | mcp__Supabase__execute_sql | mcp__Supabase__deploy_edge_function | \
  mcp__Supabase__create_branch | mcp__Supabase__reset_branch | mcp__Supabase__merge_branch | \
  mcp__Supabase__delete_branch | mcp__Supabase__rebase_branch | mcp__Supabase__create_edge_function_secret)
    ask "a write to the cloud Supabase project via MCP ($tool)" ;;
esac

cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
[[ -z "$cmd" ]] && exit 0

push_risky='(--force|--force-with-lease|--mirror|--delete|(^|[[:space:]])-[a-zA-Z]*f|[[:space:]][+][^[:space:]]|:main\b|[[:space:]]"?main"?([[:space:]]|$|[;&|])|refs/heads/main)'
if grep -qE '\bgit\b.*\bpush\b' <<<"$cmd" && grep -qE "$push_risky" <<<"$cmd"; then
  ask "a push that targets main, deletes, mirrors or force-pushes"
fi
grep -qE '\bgh\b.*\bpr\b.*\bmerge\b' <<<"$cmd" && ask "merging a pull request"
grep -qE '\bsupabase\b.*\b(db +push|db +dump|migration +(up|repair)|config +push|functions +deploy|secrets +set|link)\b' <<<"$cmd" &&
  ask "changing the remote Supabase project"
grep -qE -- '--linked|--db-url|--project-ref' <<<"$cmd" && ask "a command aimed at a remote database"
grep -qE '\bnetlify\b.*\bdeploy\b.*--prod|\bwrangler\b.*\bdeploy\b' <<<"$cmd" && ask "a production deploy"
exit 0
