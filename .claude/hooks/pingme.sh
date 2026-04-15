#!/bin/bash

source /Users/zoro/code/Portfolio/.env.hooks
list_section="Me"

INPUT=$(cat /dev/stdin)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
section_tail="${SESSION_ID: -4}"

# osascript -e 'display alert "Claude Code" message "Task complete!"'

curl -s "https://ardesian.com/api/v1/lists/claude/list_items" \
  -H "Authorization: Bearer $JIL_CLAUDE_API_KEY" \
  -X POST -H "Content-Type: application/json" \
  -d "{\"name\": \"$section_tail Task complete\", \"section\": \"$list_section\"}"

# .claude/settings.json
# "permissions": {
#   "allow": [
#     "Bash(bash /Users/zoro/code/Portfolio/.claude/hooks/pingme.sh)"
#   ]
# }
