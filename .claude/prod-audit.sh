#!/bin/bash
# Prints the latest Daily Audit and marks the Byte thread read.
#
# Usage: bash .claude/prod-audit.sh          # the newest one
#        bash .claude/prod-audit.sh 1        # the one before it
#        bash .claude/prod-audit.sh --list   # dates + ids, marks nothing
#
# Reading it IS reading it. The audit lands in the "Daily Audit" conversation as
# an ordinary companion message, so having read it here left it sitting unread
# on a phone to be cleared by hand — a badge for something nobody still needs to
# look at.
#
# TWO HALVES, TWO DOORS, and the split is the point:
#
#   read  — `.claude/prod-query.sh`, i.e. `claude_readonly`, SELECT and nothing
#           else. No write access to production, and none wanted.
#   mark  — `POST /byte/conversations/:id/read` over HTTPS, the same endpoint
#           the app itself calls when you open a thread. So it is `mark_read!`
#           for real: `last_read_at` only, no `updated_at` bump, and it
#           broadcasts to every device the way opening it on the phone does.
#
# Authenticates with PORTFOLIO_LOCAL_APIKEY out of `~/.claude/hooks/.env.hooks`,
# the same file `prod-query.sh` sources — never printed, and passed as a curl
# header rather than on a command line where `ps` could see it. CSRF is skipped
# for household accounts (User::PERMA_SAFE_IDS), which is why a bearer POST
# needs no token.
#
# --list marks nothing. Looking at what audits exist is not reading one.
set -euo pipefail

cd "$(dirname "$0")/.."

CONVO="Daily Audit"
HOST="https://ardesian.com"
ARG="${1:-0}"

source "$HOME/.claude/hooks/.env.hooks"

query() { PROD_QUERY_FLAGS="-A -t" bash .claude/prod-query.sh "$1"; }

if [ "$ARG" = "--list" ]; then
  query "SELECT m.id || '  ' || to_char(m.created_at, 'YYYY-MM-DD HH24:MI') || ' UTC  ' ||
           length(m.body) || ' chars'
         FROM byte_messages m
         JOIN byte_conversations c ON c.id = m.byte_conversation_id
         WHERE c.name = '${CONVO}' AND m.direction = 1
         ORDER BY m.id DESC LIMIT 30;"
  exit 0
fi

case "$ARG" in
  ''|*[!0-9]*) echo "usage: prod-audit.sh [n|--list] - n is how many back, 0 is newest" >&2; exit 1 ;;
esac

# The companion side of the thread. The person side is the hidden seed asking
# for the audit, which is a lot of tokens and nothing anyone wants to read.
query "SELECT m.body
       FROM byte_messages m
       JOIN byte_conversations c ON c.id = m.byte_conversation_id
       WHERE c.name = '${CONVO}' AND m.direction = 1
       ORDER BY m.id DESC
       OFFSET ${ARG} LIMIT 1;"

CONVO_ID=$(query "SELECT id FROM byte_conversations WHERE name = '${CONVO}' ORDER BY id LIMIT 1;" | tr -d '[:space:]')
case "$CONVO_ID" in
  ''|*[!0-9]*) echo "" >&2; echo "could not find a \"${CONVO}\" conversation to mark read" >&2; exit 1 ;;
esac

API_KEY="${PORTFOLIO_LOCAL_APIKEY:-}"
if [ -z "$API_KEY" ]; then
  echo "" >&2
  echo "read it, but there is no PORTFOLIO_LOCAL_APIKEY in ~/.claude/hooks/.env.hooks," >&2
  echo "so it could not be marked read. Any enabled api_keys row for your user works." >&2
  exit 1
fi

# --fail so a 401/404 is a non-zero exit rather than a body printed as success.
STATUS=$(curl -sS --fail-with-body -o /dev/null -w '%{http_code}' \
  -X POST "${HOST}/byte/conversations/${CONVO_ID}/read" \
  -H "Authorization: Bearer ${API_KEY}" 2>&1) || {
  echo "" >&2
  echo "read it, but marking it read failed (HTTP ${STATUS})" >&2
  exit 1
}

echo ""
echo "--- marked \"${CONVO}\" (#${CONVO_ID}) read ---"
