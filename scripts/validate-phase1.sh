#!/usr/bin/env bash
# GATE 1A — end-to-end local validation of the OSS credential core, NO BIG-IP.
# Issue -> confirm directory entry (+employeeType) -> bind over LDAPS (simulates the
# BIG-IP's bind, TLS included) -> revoke -> confirm gone -> confirm audit trail.
# Exits non-zero on the first failure. Prints no passwords.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
CA="${HERE}/../certs/ca.crt"

bao() { docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao bao "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

echo "== 1. issue ephemeral credential =="
CRED_JSON="$(bao read -format=json ldap/creds/warden-admin)"
USERNAME="$(jq -r '.data.username' <<<"$CRED_JSON")"
PASSWORD="$(jq -r '.data.password' <<<"$CRED_JSON")"
LEASE_ID="$(jq -r '.lease_id'      <<<"$CRED_JSON")"
[ -n "$USERNAME" ] && [ "$USERNAME" != null ] || fail "no username returned"
ok "issued uid=$USERNAME (lease $LEASE_ID)"

echo "== 2. directory entry present with employeeType=warden-admins =="
ENTRY="$(ldapsearch -x -LLL -H "ldap://${WARDEN_HOST_IP}" \
  -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PW}" \
  -b "ou=users,${BASE_DN}" "(uid=${USERNAME})" uid employeeType)"
grep -q "uid: ${USERNAME}" <<<"$ENTRY" || fail "entry not found in directory"
grep -q "employeeType: warden-admins" <<<"$ENTRY" || fail "employeeType attribute missing"
ok "entry present, employeeType=warden-admins"

echo "== 3. bind over LDAPS (simulates the BIG-IP auth bind, TLS validated) =="
WHO="$(LDAPTLS_CACERT="$CA" ldapwhoami -x \
  -H "ldaps://${WARDEN_HOST_IP}" \
  -D "uid=${USERNAME},ou=users,${BASE_DN}" -w "${PASSWORD}")"
grep -q "uid=${USERNAME}" <<<"$WHO" || fail "LDAPS bind failed (got: $WHO)"
ok "LDAPS bind succeeded: $WHO"

echo "== 4. revoke lease =="
bao lease revoke "$LEASE_ID" >/dev/null
ok "revoked $LEASE_ID"

echo "== 5. entry gone after revoke (revocation is async — poll up to 10s); bind then fails =="
GONE=""
for _ in $(seq 1 10); do
  GONE="$(ldapsearch -x -LLL -H "ldap://${WARDEN_HOST_IP}" \
    -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PW}" \
    -b "ou=users,${BASE_DN}" "(uid=${USERNAME})" uid || true)"
  grep -q 'uid:' <<<"$GONE" || break
  sleep 1
done
[ -z "$(grep 'uid:' <<<"$GONE" || true)" ] || fail "entry still present 10s after revoke"
if LDAPTLS_CACERT="$CA" ldapwhoami -x -H "ldaps://${WARDEN_HOST_IP}" \
     -D "uid=${USERNAME},ou=users,${BASE_DN}" -w "${PASSWORD}" >/dev/null 2>&1; then
  fail "bind still succeeds after revoke"
fi
ok "entry deleted, revoked credential rejected"

echo "== 6. audit trail present =="
docker exec openbao grep -q 'ldap/creds/warden-admin' /openbao/logs/openbao-audit.log \
  || fail "no issuance event in audit log"
ok "issuance recorded in /openbao/logs/openbao-audit.log"

echo
echo "GATE 1A PASSED — OSS credential core validated end-to-end."
