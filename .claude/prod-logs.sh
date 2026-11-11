#!/bin/bash
# Searches production's logs. Read-only: it greps, and nothing else runs there.
#
# Usage: bash .claude/prod-logs.sh PATTERN [LINES] [FILE]
#        bash .claude/prod-logs.sh --list
#        bash .claude/prod-logs.sh "retracted unbacked.*message=10121"
#        bash .claude/prod-logs.sh "ByteSyncWorker" 50 sidekiq.log
#        bash .claude/prod-logs.sh "POST /jil/trigger " 50 "nginx/portfolio.access.log*"
#        bash .claude/prod-logs.sh "Puma" 50 journal:puma_portfolio_production
#
# PATTERN is an extended regex. LINES is how many of the last matches to show
# (default 100). FILE (default production.log) is one of:
#   - a name under the app's shared/log
#   - nginx/NAME, short for /var/log/nginx/NAME
#   - any path under /var/log
#   - journal:UNIT, that systemd unit's journal
# A file may end in `*` to take in its rotations too: they are read oldest
# first, gzipped ones included, so the last matches are still the newest.
# --list shows every log file there is, marking the ones the ssh user can't read.
#
# Anything shaped like a credential is blanked on the server, before it leaves:
# a log line that echoes a header or a token should never land in a terminal.
source "$HOME/.claude/hooks/.env.hooks"

REDACT='s/(bearer|basic) +[^ ,"'"'"']+/\1 <redacted>/Ig; s/eyJ[A-Za-z0-9._-]{20,}/<jwt>/g; s/((authorization|bearer|token|secret|password|api[_-]?key)[^ :=]*["'"'"']?[ :=]+["'"'"']?)[^ ,"'"'"'&]+/\1<redacted>/Ig'

if [[ "$1" == "--list" ]]; then
  MODE="list"
else
  MODE="search"
  PATTERN="${1:?usage: prod-logs.sh PATTERN [LINES] [FILE] | --list}"
  LINES="${2:-100}"
  FILE="${3:-production.log}"

  [[ "$LINES" =~ ^[0-9]+$ ]] || { echo "LINES must be a number" >&2; exit 1; }
  [[ "$FILE" == *..* ]] && { echo "FILE must not climb out with .." >&2; exit 1; }
  [[ "$FILE" == nginx/* ]] && FILE="/var/log/$FILE"
  [[ "$FILE" =~ ^(journal:[A-Za-z0-9@._-]+|/var/log/[A-Za-z0-9._*/-]+|[A-Za-z0-9._*-]+)$ ]] ||
    { echo "FILE must be a shared/log name, nginx/NAME, a /var/log path or journal:UNIT" >&2; exit 1; }
fi

# The remote half arrives on stdin and its arguments are quoted here, so no
# pattern or file name is ever parsed as shell on the server.
ssh -i "$PROD_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${PROD_SSH_USER}@${PROD_SSH_HOST}" \
  "bash -s -- $(printf "%q " "$MODE" "${PATTERN:-}" "${LINES:-}" "${FILE:-}" "$REDACT")" <<'REMOTE'
mode="$1"; pattern="$2"; lines="$3"; target="$4"; redact="$5"
shared="$HOME/apps/portfolio/shared/log"

if [[ "$mode" == "list" ]]; then
  find "$shared" /var/log -type f \( -name "*.log*" -o -name "syslog*" -o -name "*.gz" \) \
    \( -readable -printf "%TY-%Tm-%Td %TH:%TM %10s  %p\n" \
    -o -printf "%TY-%Tm-%Td %TH:%TM %10s  %p  (UNREADABLE)\n" \) 2>/dev/null | sort -k4
  exit 0
fi

if [[ "$target" == journal:* ]]; then
  journalctl -u "${target#journal:}" --no-pager -o short-iso 2>&1 |
    grep -E -- "$pattern" | tail -n "$lines" | sed -E "$redact"
  exit 0
fi

[[ "$target" == /* ]] || target="$shared/$target"
# Unquoted on purpose: a trailing `*` expands to the file and its rotations,
# and `ls -tr` puts them oldest first.
files=$(ls -1tr -- $target 2>/dev/null)
[[ -n "$files" ]] || { echo "No file matches $target" >&2; exit 1; }

readable=()
while IFS= read -r file; do
  if [[ -r "$file" ]]; then
    readable+=("$file")
  else
    echo "Can't read $file as $(whoami) - it needs the adm group" >&2
  fi
done <<< "$files"
[[ ${#readable[@]} -gt 0 ]] || exit 1

zgrep -h -E -- "$pattern" "${readable[@]}" | tail -n "$lines" | sed -E "$redact"
REMOTE
