#!/bin/bash

source /Users/zoro/code/Portfolio/.env.hooks
list_section="Me"

INPUT=$(cat /dev/stdin)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
session_tail="${SESSION_ID: -4}"

curl -s "https://ardesian.com/api/v1/lists/claude/list_items" \
  -H "Authorization: Bearer $JIL_CLAUDE_API_KEY" \
  -X POST -H "Content-Type: application/json" \
  -d "{\"name\": \">$session_tail Done\", \"section\": \"$list_section\"}"
