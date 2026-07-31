#!/usr/bin/env bash
# GATE 1A — end-to-end local validation of the OSS credential core, NO BIG-IP.
# Issue -> confirm directory entry (+admin stamp when attribute-mapped) -> bind over
# LDAPS (simulates the BIG-IP's bind, TLS included) -> revoke -> confirm gone ->
# confirm audit trail. Exits non-zero on the first failure. Prints no passwords.
# Works in both modes: bundled OpenLDAP and an external directory (AD/LDAP).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
# shellcheck disable=SC1091
. "${HERE}/lib/directory.sh"

# admin-read connection (existence checks) + the LDAPS bind the BIG-IP would do
if warden_is_bundled; then
  READ_URI="ldap://${WARDEN_HOST_IP}"
  READ_DN="cn=admin,${BASE_DN}";      READ_PW="${LDAP_ADMIN_PW}"
  BIND_URI="ldaps://${WARDEN_HOST_IP}"
  CA="${HERE}/../certs/ca.crt"
else
  READ_URI="ldaps://${WARDEN_LDAP_HOST}:${WARDEN_LDAPS_PORT}"
  READ_DN="${WARDEN_BIND_DN}";        READ_PW="${BIND_PW}"
  BIND_URI="${READ_URI}"
  case "${WARDEN_LDAP_CA_FILE}" in /*) CA="${WARDEN_LDAP_CA_FILE}";; *) CA="${HERE}/../${WARDEN_LDAP_CA_FILE}";; esac
fi
export LDAPTLS_CACERT="$CA"
ATTR="${WARDEN_PRIV_DN_ATTR}"

bao() { docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao bao "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

echo "== 1. issue ephemeral credential =="
CRED_JSON="$(bao read -format=json ldap/creds/warden-admin)"
USERNAME="$(jq -r '.data.username' <<<"$CRED_JSON")"
PASSWORD="$(jq -r '.data.password' <<<"$CRED_JSON")"
LEASE_ID="$(jq -r '.lease_id'      <<<"$CRED_JSON")"
[ -n "$USERNAME" ] && [ "$USERNAME" != null ] || fail "no username returned"
ok "issued ${ATTR}=$USERNAME (lease $LEASE_ID)"

echo "== 2. directory entry present =="
ENTRY="$(ldapsearch -x -LLL -H "$READ_URI" -D "$READ_DN" -w "$READ_PW" \
  -b "${WARDEN_PRIV_SEARCH_BASE}" "(${ATTR}=${USERNAME})" "${ATTR}" "${WARDEN_ADMIN_ROLE_ATTR}")"
grep -qi "^${ATTR}: ${USERNAME}" <<<"$ENTRY" || fail "entry not found in directory"
# the admin stamp only exists when the role mapping is attribute-based; with a group
# mapping (memberOf) ephemeral accounts are deliberately unstamped (see docs/directory.md)
if [ "${WARDEN_ADMIN_ROLE_ATTR}" != memberOf ]; then
  grep -q "${WARDEN_ADMIN_ROLE_ATTR}: ${WARDEN_ADMIN_ROLE_VALUE}" <<<"$ENTRY" \
    || fail "${WARDEN_ADMIN_ROLE_ATTR} attribute missing"
  ok "entry present, ${WARDEN_ADMIN_ROLE_ATTR}=${WARDEN_ADMIN_ROLE_VALUE}"
else
  ok "entry present (group mapping — no stamp expected on ephemeral accounts)"
fi

echo "== 3. bind over LDAPS (simulates the BIG-IP auth bind, TLS validated) =="
WHO="$(ldapwhoami -x -H "$BIND_URI" \
  -D "${ATTR}=${USERNAME},${WARDEN_PRIV_SEARCH_BASE}" -w "${PASSWORD}")"
grep -qi "${USERNAME}" <<<"$WHO" || fail "LDAPS bind failed (got: $WHO)"
ok "LDAPS bind succeeded: $WHO"

echo "== 4. revoke lease =="
bao lease revoke "$LEASE_ID" >/dev/null
ok "revoked $LEASE_ID"

echo "== 5. entry gone after revoke (revocation is async — poll up to 10s); bind then fails =="
GONE=""
for _ in $(seq 1 10); do
  GONE="$(ldapsearch -x -LLL -H "$READ_URI" -D "$READ_DN" -w "$READ_PW" \
    -b "${WARDEN_PRIV_SEARCH_BASE}" "(${ATTR}=${USERNAME})" "${ATTR}" || true)"
  grep -qi "^${ATTR}:" <<<"$GONE" || break
  sleep 1
done
[ -z "$(grep -i "^${ATTR}:" <<<"$GONE" || true)" ] || fail "entry still present 10s after revoke"
if ldapwhoami -x -H "$BIND_URI" \
     -D "${ATTR}=${USERNAME},${WARDEN_PRIV_SEARCH_BASE}" -w "${PASSWORD}" >/dev/null 2>&1; then
  fail "bind still succeeds after revoke"
fi
ok "entry deleted, revoked credential rejected"

echo "== 6. audit trail present =="
docker exec openbao grep -q 'ldap/creds/warden-admin' /openbao/logs/openbao-audit.log \
  || fail "no issuance event in audit log"
ok "audit log records the issuance"

echo
echo "GATE 1A PASSED"
