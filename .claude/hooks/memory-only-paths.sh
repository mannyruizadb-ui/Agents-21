#!/usr/bin/env bash
# PreToolUse guard for reviewer agents: memory auto-enables Write/Edit, so allow writes
# only inside the agent's own memory folder. Usage: memory-only-paths.sh <agent-name>
agent="${1:?agent name required}"
path=$(jq -r '.tool_input.file_path // empty')
allowed="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/agent-memory/${agent}/"
case "$(realpath -m "$path")/" in
  "$(realpath -m "$allowed")"/*) exit 0 ;;
esac
echo "Blocked: ${agent} is read-only; it may only write to .claude/agent-memory/${agent}/." >&2
exit 2
