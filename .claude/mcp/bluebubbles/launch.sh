#!/bin/bash
# Wrapper so the MCP process inherits BLUE_BUBBLES_SERVER_PASSWORD (and any
# other env vars) even when Claude Code is launched from the Dock and never
# sources ~/.zshenv itself.
set -e
[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv"
exec /Users/zoro/.local/bin/uv run --quiet --script \
  "$(dirname "$0")/server.py"
