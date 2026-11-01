#!/usr/bin/env bash
# PreToolUse guard for docs-keeper: documentation paths only.
path=$(realpath -m "$(jq -r '.tool_input.file_path // empty')")
root=$(realpath -m "${CLAUDE_PROJECT_DIR:-$PWD}")
case "$path" in
  "$root/.claude/CLAUDE.md" | "$root"/research/* | "$root"/docs/* | "$root"/.claude/agent-memory/docs-keeper/*) exit 0 ;;
esac
echo "Blocked: docs-keeper may only edit .claude/CLAUDE.md, research/ and docs/." >&2
exit 2
