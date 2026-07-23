#!/usr/bin/env bash
# T1.5 — configure OpenBao's LDAP secrets engine to mint ephemeral, leased LDAP
# accounts in OpenLDAP. Runs `bao` inside the openbao container (dev mode); the
# openbao/ dir is bind-mounted to /openbao so @file references resolve.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a

bao() { docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao bao "$@"; }

bao secrets enable ldap || true

bao write sys/policies/password/pua-ephemeral policy=@/openbao/pw-policy.hcl

# bind to OpenLDAP over the compose network (service name), admin bind creates users
bao write ldap/config \
  binddn="cn=admin,${BASE_DN}" bindpass="${LDAP_ADMIN_PW}" \
  url="ldap://openldap:389" schema=openldap password_policy=pua-ephemeral

bao write ldap/role/pua-admin \
  creation_ldif=@/openbao/creation.ldif \
  deletion_ldif=@/openbao/deletion.ldif \
  rollback_ldif=@/openbao/rollback.ldif \
  username_template='pua-{{random 10 | lowercase}}' \
  default_ttl=15m max_ttl=1h

bao audit enable file file_path=/tmp/openbao-audit.log || true

echo "==> OpenBao LDAP secrets engine configured (role: ldap/creds/pua-admin)"
