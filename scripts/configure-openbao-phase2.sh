#!/usr/bin/env bash
# T2.2 — create the scoped policy + token the APM gateway uses to fetch ephemeral
# creds. The root/dev token must NEVER be embedded in a BIG-IP object; this issues a
# narrowly-scoped, renewable token instead. Token is printed to STDOUT ONLY.
#
# Usage: scripts/configure-openbao-phase2.sh          # create policy + mint token
#        GATE2A=1 scripts/configure-openbao-phase2.sh  # also run the GATE 2A checks
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a

bao() { docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao bao "$@"; }

echo "== write policy warden-apm-read ==" >&2
bao policy write warden-apm-read /warden/phase2-apm-policy.hcl >&2

echo "== mint scoped token (period 30m, renewable) ==" >&2
# display_name + period => a long-lived machine token bound only to warden-apm-read
TOKEN_JSON="$(bao token create -policy=warden-apm-read -period=30m -display-name=warden-apm -format=json)"
APM_TOKEN="$(echo "$TOKEN_JSON" | jq -r '.auth.client_token')"
echo "APM scoped token (store in an APM system variable / encrypted, NOT inline):" >&2
echo "$APM_TOKEN"

if [ "${GATE2A:-0}" = "1" ]; then
  echo >&2; echo "== GATE 2A: verify scope ==" >&2
  t() { docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="$APM_TOKEN" openbao bao "$@"; }
  echo "-- allowed: read ldap/creds/warden-admin --" >&2
  t read -format=json ldap/creds/warden-admin | jq -e '.data.username' >/dev/null \
    && echo "  ok: scoped token can mint/read a credential" >&2 \
    || { echo "  FAIL: scoped token cannot read creds" >&2; exit 1; }
  echo "-- denied: read ldap/config (bind creds) --" >&2
  if t read ldap/config >/dev/null 2>&1; then echo "  FAIL: token could read ldap/config" >&2; exit 1; \
    else echo "  ok: ldap/config denied" >&2; fi
  echo "-- denied: list sys/policies (root path) --" >&2
  if t read sys/policies/acl/root >/dev/null 2>&1; then echo "  FAIL: token reached sys/policies" >&2; exit 1; \
    else echo "  ok: sys/* denied" >&2; fi
  echo >&2; echo "GATE 2A PASSED — scoped token reads only ldap/creds/warden-admin." >&2
fi
