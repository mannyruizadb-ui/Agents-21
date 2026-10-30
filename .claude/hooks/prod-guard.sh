#!/usr/bin/env bash
# PreToolUse guard (all agents): production-affecting commands need the owner's approval,
# signalled by running them with RELEASE_APPROVED=1 after the owner confirms (/release).
cmd=$(jq -r '.tool_input.command // empty')
[[ "$cmd" == *RELEASE_APPROVED=1* ]] && exit 0
deny() { echo "Blocked: $1 needs explicit owner approval (see CLAUDE.md 'Never do without explicit approval')." >&2; exit 2; }
grep -qE 'supabase +db +push|supabase +link' <<<"$cmd" && deny "pushing migrations to a linked/remote database"
grep -qE 'netlify +deploy.*--prod' <<<"$cmd" && deny "a production deploy"
grep -qE 'git +push.*(--force|-f( |$)|--force-with-lease)' <<<"$cmd" && deny "a force-push"
grep -qE 'git +push.*([ :]|refs/heads/)main( |$)' <<<"$cmd" && deny "pushing to main"
exit 0
