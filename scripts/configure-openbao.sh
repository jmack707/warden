#!/usr/bin/env bash
# T1.5 — configure OpenBao's LDAP secrets engine to mint ephemeral, leased LDAP
# accounts in OpenLDAP. Runs `bao` inside the openbao container (dev mode); the
# openbao/ dir is bind-mounted to /openbao so @file references resolve.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
# shellcheck disable=SC1091
. "${HERE}/lib/directory.sh"

bao() { docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao bao "$@"; }

bao secrets enable ldap || true

bao write sys/policies/password/warden-ephemeral policy=@/warden/pw-policy.hcl

# bundled: reach OpenLDAP over the compose network by service name; external: over the
# wire (LDAPS) to your directory. The bind account must be able to reset passwords on
# WARDEN_PRIV_SEARCH_BASE — nothing else.
bao write ldap/config \
  binddn="${WARDEN_DIR_ADMIN_DN}" bindpass="${WARDEN_DIR_ADMIN_PW}" \
  url="${WARDEN_BAO_LDAP_URL}" schema="${WARDEN_LDAP_SCHEMA}" password_policy=warden-ephemeral

# The ephemeral role's LDIFs are templated (the privileged subtree + admin stamp are
# config, not constants) — render them into the container's bind mount.
# sed drops blank lines: an empty stamp (group-based mapping) would otherwise leave one,
# and a blank line in LDIF terminates the entry.
for f in creation deletion rollback; do
  envsubst '${WARDEN_PRIV_SEARCH_BASE} ${WARDEN_PRIV_STAMP_LDIF}' \
    < "${HERE}/../openbao/${f}.ldif.tmpl" | sed '/^[[:space:]]*$/d' > "${HERE}/../openbao/${f}.ldif"
done

bao write ldap/role/warden-admin \
  creation_ldif=@/warden/creation.ldif \
  deletion_ldif=@/warden/deletion.ldif \
  rollback_ldif=@/warden/rollback.ldif \
  username_template='warden-{{random 10 | lowercase}}' \
  default_ttl=15m max_ttl=1h

# Audit device is declared in openbao.hcl (2.x no longer allows API enablement);
# just confirm it registered.
echo "== audit devices =="
bao audit list || echo "WARN: no audit device — check openbao.hcl / -config"

echo "==> OpenBao LDAP secrets engine configured (role: ldap/creds/warden-admin)"
