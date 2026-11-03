#!/bin/bash
# Prints the failures production reported, grouped, most-repeated first.
#
# Usage: bash .claude/prod-errors.sh          # the last 24 hours
#        bash .claude/prod-errors.sh 72       # the last 72 hours
#
# The same rows the Daily Audit's last section and /system/errors are built
# from (see ErrorReport + ByteDailyAudit#errors_block), for the times the
# question comes up here rather than in a browser. A null `channel` means the failure was
# recorded and never announced anywhere, which makes it the kind nobody has
# seen; the sample row id is there to open one up:
#
#   bash .claude/prod-query.sh "SELECT backtrace, extra FROM error_reports WHERE id = 931"
#
# Read-only, like everything that goes through prod-query.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

HOURS="${1:-24}"
case "$HOURS" in
  ''|*[!0-9]*) echo "usage: prod-errors.sh [hours] - how far back to look, default 24" >&2; exit 1 ;;
esac

PROD_QUERY_FLAGS="-A -t" bash .claude/prod-query.sh "
  SELECT count(*) || 'x  ' ||
         to_char(min(error_reports.created_at) AT TIME ZONE 'America/Denver', 'Mon DD HH12:MI AM') || ' to ' ||
         to_char(max(error_reports.created_at) AT TIME ZONE 'America/Denver', 'Mon DD HH12:MI AM') ||
         '  ' || CASE min(layer) WHEN 'frontend' THEN 'FE' ELSE 'BE' END || '/' || coalesce(min(tag), '?') ||
         '  [' || min(section) || '] ' ||
         coalesce(min(error_class) || ': ', '') ||
         replace(substr(coalesce(min(message), ''), 1, 160), E'\n', ' ') ||
         '  (row ' || max(error_reports.id) || ')' ||
         CASE WHEN count(channel) = 0 THEN '  NEVER ANNOUNCED' ELSE '' END ||
         coalesce('  ' || upper(CASE min(s.status) WHEN 0 THEN 'resolved' WHEN 1 THEN 'ignored' END), '')
  FROM error_reports
  LEFT JOIN error_statuses s USING (fingerprint)
  WHERE error_reports.created_at > now() - interval '${HOURS} hours'
  GROUP BY fingerprint
  ORDER BY count(*) DESC, max(error_reports.created_at) DESC;"
