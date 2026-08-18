#!/usr/bin/env bash
# healthcheck.sh — poll the PanDA server until it responds healthy.
# Usage: ./scripts/healthcheck.sh [max-wait-seconds]
set -euo pipefail

PANDA_URL="${PANDA_URL:-http://localhost:25080/server/panda}"
PANDA_API_URL="${PANDA_API_URL:-${PANDA_URL%/server/panda}/api/v1}"
HEALTH_URL="${PANDA_API_URL}/system/is_alive"
MAX_WAIT="${1:-120}"
INTERVAL=5
elapsed=0

echo "Waiting for PanDA server at ${HEALTH_URL} (timeout: ${MAX_WAIT}s)..."

until curl -sf "${HEALTH_URL}" | grep -q "'success': True\|\"success\": true"; do
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        echo "ERROR: PanDA server did not become healthy within ${MAX_WAIT}s." >&2
        exit 1
    fi
    echo "  ...not ready yet (${elapsed}s elapsed), retrying in ${INTERVAL}s"
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

echo "PanDA server is healthy after ${elapsed}s."
