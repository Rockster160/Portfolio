#!/bin/bash
# Local psql query against development DB
# Usage: bash .claude/dev-query.sh "SELECT 1"

QUERY="${1:-$(cat)}"

# Force read-only at the session level — any INSERT/UPDATE/DELETE/DDL
# will fail with "cannot execute ... in a read-only transaction".
PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=30000" \
  PGPASSWORD="$PORTFOLIO_DB_PASS" \
  psql -h localhost -p 5432 -U "${PORTFOLIO_DB_USER:-$USER}" -d Portfolio_development \
    -v ON_ERROR_STOP=1 \
    -c "$QUERY" 2>&1
