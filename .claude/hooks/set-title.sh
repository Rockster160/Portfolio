#!/bin/bash

INPUT=$(cat /dev/stdin)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
session_tail="${SESSION_ID: -4}"

# Try to get conversation name from transcript
conv_name=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  conv_name=$(grep -o '"slug":"[^"]*"' "$TRANSCRIPT" | tail -1 | sed 's/"slug":"//;s/"//')
fi

if [ -n "$conv_name" ]; then
  title="[$session_tail] $conv_name"
else
  title="[$session_tail] Claude Code CLI"
fi

# Set iTerm2 tab title
printf '\033]1;%s\007' "$title" > /dev/tty
