#!/usr/bin/env bash
# SubagentStop: append a one-line record so meta can see which agents ran.
dir="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/state"; mkdir -p "$dir"
jq -c '{at: (now | todate), agent: (.agent_type // .subagent_type // "unknown"), session: .session_id}' >>"$dir/agent-runs.log"
exit 0
