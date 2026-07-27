#!/usr/bin/env bash
# Stage A — OpenBao LDAP secrets engine STATIC roles: OpenBao takes over the password
# of a pre-existing privileged account (uid=<CN>,ou=users) and rotates it to a random
# value. `ldap/static-cred/<CN>` returns the current username+password for APM to inject;
# `ldap/rotate-role/<CN>` forces a fresh rotation (call per session for a one-time pw).
#
# Usage: scripts/configure-openbao-static.sh [CN ...]   (default: alice.admin)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
bao(){ docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao bao "$@"; }
CNS=("$@"); [ ${#CNS[@]} -gt 0 ] || CNS=(alice.admin)

for CN in "${CNS[@]}"; do
  echo "== static role for ${CN} =="
  bao write "ldap/static-role/${CN}" \
    dn="uid=${CN},ou=users,${BASE_DN}" \
    username="${CN}" \
    rotation_period=24h >/dev/null
  echo "  rotating to a fresh random password..."
  bao write -f "ldap/rotate-role/${CN}" >/dev/null 2>&1 || true
  # show username + password length only (never print the password)
  J="$(bao read -format=json "ldap/static-cred/${CN}")"
  U="$(jq -r '.data.username' <<<"$J")"; L="$(jq -r '.data.password|length' <<<"$J")"
  echo "  static-cred/${CN}: username=${U} password(len=${L}) — OpenBao-managed"
done
echo "Done. APM reads ldap/static-cred/<CN> (scoped token) and injects username+password."
