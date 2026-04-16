#!/bin/bash
# On-demand SSH tunnel + psql query against production
# Usage: bash .claude/prod-query.sh "SELECT 1"

source "$HOME/.claude/hooks/.env.hooks"

LOCAL_PORT=$(( (RANDOM % 10000) + 50000 ))

# Read query from arg or stdin
QUERY="${1:-$(cat)}"

# Open SSH tunnel in background
ssh -f -N -L "${LOCAL_PORT}:localhost:5432" \
  -i "$PROD_SSH_KEY" \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=10 \
  "${PROD_SSH_USER}@${PROD_SSH_HOST}" 2>/dev/null

# Wait for tunnel to be ready
for i in $(seq 1 20); do
  pg_isready -h localhost -p "$LOCAL_PORT" -q 2>/dev/null && break
  sleep 0.25
done

# Run query
PGPASSWORD="$PROD_DB_PASS" psql -h localhost -p "$LOCAL_PORT" -U "$PROD_DB_USER" -d "$PROD_DB_NAME" -c "$QUERY" 2>&1

# Kill the tunnel
pkill -f "ssh.*-L ${LOCAL_PORT}:localhost:5432.*${PROD_SSH_HOST}" 2>/dev/null
