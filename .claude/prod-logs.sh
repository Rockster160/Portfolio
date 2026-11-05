#!/bin/bash
# Searches production's logs. Read-only: it greps, and nothing else runs there.
#
# Usage: bash .claude/prod-logs.sh PATTERN [LINES] [FILE]
#        bash .claude/prod-logs.sh "retracted unbacked.*message=10121"
#        bash .claude/prod-logs.sh "ByteSyncWorker" 50 sidekiq.log
#
# PATTERN is an extended regex. LINES is how many of the last matches to show
# (default 100). FILE is a name under shared/log (default production.log).
#
# Anything shaped like a credential is blanked on the server, before it leaves:
# a log line that echoes a header or a token should never land in a terminal.
source "$HOME/.claude/hooks/.env.hooks"

PATTERN="${1:?usage: prod-logs.sh PATTERN [LINES] [FILE]}"
LINES="${2:-100}"
FILE="${3:-production.log}"

[[ "$LINES" =~ ^[0-9]+$ ]] || { echo "LINES must be a number" >&2; exit 1; }
[[ "$FILE" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "FILE must be a plain file name" >&2; exit 1; }

REDACT='s/(bearer|basic) +[^ ,"'"'"']+/\1 <redacted>/Ig; s/eyJ[A-Za-z0-9._-]{20,}/<jwt>/g; s/((authorization|bearer|token|secret|password|api[_-]?key)[^ :=]*["'"'"']?[ :=]+["'"'"']?)[^ ,"'"'"'&]+/\1<redacted>/Ig'

ssh -i "$PROD_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${PROD_SSH_USER}@${PROD_SSH_HOST}" \
  "grep -h -E -- $(printf %q "$PATTERN") ~/apps/portfolio/shared/log/$FILE | tail -n $LINES | sed -E $(printf %q "$REDACT")"
