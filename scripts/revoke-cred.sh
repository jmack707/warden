#!/usr/bin/env bash
# T1.6 — revoke a lease by ID; deletes the ephemeral LDAP entry immediately.
# Usage: revoke-cred.sh <lease_id>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
[ $# -eq 1 ] || { echo "usage: $0 <lease_id>" >&2; exit 2; }

bao() { docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao bao "$@"; }

bao lease revoke "$1"
echo "==> revoked $1"
