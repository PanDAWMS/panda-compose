#!/bin/bash
# Bootstrap the CI Rucio instance with the RSE, protocol and scopes that the
# Harvester RucioStager plugin expects.
#
# The rucio-init container creates the schema and the 'root' account, but it
# does not create any RSE or scope. This script adds the minimum needed for
# RucioStager to upload job output:
#
#   * RSE MOCK-POSIX with a posix 'file' protocol rooted at /tmp/rucio_rse
#   * scope user.alice (stager default output scope)
#   * scope mock        (input datasets used by integration tests)
#
# Idempotent: re-running is a no-op (already-exists responses are accepted).
#
# Usage: scripts/bootstrap-rucio.sh [rucio-container-name]
set -euo pipefail

CONTAINER="${1:-${PANDA_COMPOSE_PROJECT:-panda-compose}-rucio-1}"
RUCIO_ACCOUNT="${RUCIO_ACCOUNT:-root}"
RUCIO_USERNAME="${RUCIO_USERNAME:-ddmlab}"
RUCIO_PASSWORD="${RUCIO_PASSWORD:-secret}"
RSE_NAME="${RSE_NAME:-MOCK-POSIX}"
RSE_PREFIX="${RSE_PREFIX:-/tmp/rucio_rse/}"
SCOPES="${SCOPES:-user.alice mock}"

in_rucio() { docker exec "$CONTAINER" "$@"; }

echo "Authenticating to Rucio as ${RUCIO_ACCOUNT} ..."
TOKEN=$(in_rucio curl -s -i \
  -H "X-Rucio-Account: ${RUCIO_ACCOUNT}" \
  -H "X-Rucio-Username: ${RUCIO_USERNAME}" \
  -H "X-Rucio-Password: ${RUCIO_PASSWORD}" \
  http://localhost/auth/userpass | grep -i '^x-rucio-auth-token:' | tr -d '\r' | awk '{print $2}')

if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: failed to obtain a Rucio auth token from ${CONTAINER}" >&2
  exit 1
fi
echo "  got token ${TOKEN:0:20}..."

# POST that tolerates 'already exists' (409) so the script stays idempotent.
post() {
  local path="$1" body="${2:-}" desc="$3" code
  if [[ -n "${body}" ]]; then
    code=$(in_rucio curl -s -o /dev/null -w '%{http_code}' -X POST \
      -H "X-Rucio-Auth-Token: ${TOKEN}" -H 'Content-Type: application/json' \
      -d "${body}" "http://localhost${path}")
  else
    code=$(in_rucio curl -s -o /dev/null -w '%{http_code}' -X POST \
      -H "X-Rucio-Auth-Token: ${TOKEN}" "http://localhost${path}")
  fi
  case "${code}" in
    201|409) echo "  ${desc}: OK (HTTP ${code})" ;;
    *)       echo "  ${desc}: FAILED (HTTP ${code})" >&2; return 1 ;;
  esac
}

echo "Creating RSE ${RSE_NAME} ..."
post "/rses/${RSE_NAME}" "" "rse ${RSE_NAME}"

echo "Adding posix protocol to ${RSE_NAME} ..."
post "/rses/${RSE_NAME}/protocols/file" \
  "{\"hostname\":\"localhost\",\"port\":0,\"prefix\":\"${RSE_PREFIX}\",\"impl\":\"rucio.rse.protocols.posix.Default\",\"domains\":{\"lan\":{\"read\":1,\"write\":1,\"delete\":1},\"wan\":{\"read\":1,\"write\":1,\"delete\":1}}}" \
  "protocol file://${RSE_PREFIX}"

for scope in ${SCOPES}; do
  echo "Adding scope ${scope} ..."
  post "/accounts/${RUCIO_ACCOUNT}/scopes/${scope}" "" "scope ${scope}"
done

# Without an explicit local RSE limit the account has zero quota, and
# UploadClient fails at the add_replication_rule step with
# InsufficientAccountLimit. -1 means unlimited.
echo "Granting ${RUCIO_ACCOUNT} unlimited quota on ${RSE_NAME} ..."
post "/accounts/${RUCIO_ACCOUNT}/limits/local/${RSE_NAME}" \
  '{"bytes": -1}' "quota ${RUCIO_ACCOUNT}@${RSE_NAME}"

echo "Verifying ..."
in_rucio curl -s -H "X-Rucio-Auth-Token: ${TOKEN}" http://localhost/rses/ \
  | python3 -c 'import sys,json;[print("  rse:",json.loads(l)["rse"]) for l in sys.stdin if l.strip()]'
in_rucio curl -s -H "X-Rucio-Auth-Token: ${TOKEN}" http://localhost/scopes/ \
  | python3 -c 'import sys,json;print("  scopes:",", ".join(json.load(sys.stdin)))'

echo "Rucio bootstrap complete."
