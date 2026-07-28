#!/usr/bin/env bash
# Mint a least-privilege OpenBao token for the APM in-session fetch: it may only READ
# ldap/static-cred/* and ROTATE ldap/rotate-role/* (no config, no root paths). Prints
# ONLY the token to stdout (for the iRule datagroup); everything else to stderr.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
bao(){ docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao bao "$@"; }

bao policy write warden-apm-static - >&2 <<'HCL'
path "ldap/static-cred/*" { capabilities = ["read"] }
path "ldap/rotate-role/*" { capabilities = ["create","update"] }
HCL

bao token create -policy=warden-apm-static -period=768h -display-name=warden-apm-fetch -format=json \
  | jq -r '.auth.client_token'
