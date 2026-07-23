#!/usr/bin/env bash
# T1.6 — issue an ephemeral BIG-IP admin credential. Output goes to STDOUT ONLY;
# never redirect this into a file, log, or commit message.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a

bao() { docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao bao "$@"; }

bao read -format=json ldap/creds/pua-admin \
  | jq '{username:.data.username, password:.data.password, lease_id:.lease_id, ttl:.lease_duration}'
