#!/usr/bin/env bash
# T1.5 — configure OpenBao's LDAP secrets engine to mint ephemeral, leased LDAP
# accounts in OpenLDAP. Runs `bao` inside the openbao container (dev mode); the
# openbao/ dir is bind-mounted to /openbao so @file references resolve.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a

bao() { docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao bao "$@"; }

bao secrets enable ldap || true

bao write sys/policies/password/pua-ephemeral policy=@/pua/pw-policy.hcl

# bind to OpenLDAP over the compose network (service name), admin bind creates users
bao write ldap/config \
  binddn="cn=admin,${BASE_DN}" bindpass="${LDAP_ADMIN_PW}" \
  url="ldap://openldap:389" schema=openldap password_policy=pua-ephemeral

bao write ldap/role/pua-admin \
  creation_ldif=@/pua/creation.ldif \
  deletion_ldif=@/pua/deletion.ldif \
  rollback_ldif=@/pua/rollback.ldif \
  username_template='pua-{{random 10 | lowercase}}' \
  default_ttl=15m max_ttl=1h

# Audit device is declared in openbao.hcl (2.x no longer allows API enablement);
# just confirm it registered.
echo "== audit devices =="
bao audit list || echo "WARN: no audit device — check openbao.hcl / -config"

echo "==> OpenBao LDAP secrets engine configured (role: ldap/creds/pua-admin)"
