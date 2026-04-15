#!/bin/bash

source /Users/zoro/code/Portfolio/.env.hooks
list_section="Me"
CACHE_FILE="/tmp/claude-permission-pending.txt"

INPUT=$(cat /dev/stdin)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
section_tail="${SESSION_ID: -4}"

# Add session to pending cache (if not already there)
grep -qxF "$SESSION_ID" "$CACHE_FILE" 2>/dev/null || echo "$SESSION_ID" >> "$CACHE_FILE"

curl -s "https://ardesian.com/api/v1/lists/claude/list_items" \
  -H "Authorization: Bearer $JIL_CLAUDE_API_KEY" \
  -X POST -H "Content-Type: application/json" \
  -d "{\"name\": \">$section_tail Permission\", \"section\": \"$list_section\"}"
