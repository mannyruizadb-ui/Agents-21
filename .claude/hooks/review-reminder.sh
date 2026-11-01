#!/usr/bin/env bash
# PostToolUse (all agents): after SQL or Edge Function edits, remind that review is required.
path=$(jq -r '.tool_input.file_path // empty')
if [[ "$path" == */supabase/migrations/* || "$path" == */supabase/functions/* ]]; then
  jq -n '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: "SQL/auth/server code changed: security-reviewer PASS is required before commit (research/agents.md §5.5)."}}'
fi
exit 0
