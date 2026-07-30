#!/usr/bin/env bash
# Create the three cert->group->access test principals + their client certs.
#   - memberof overlay (idempotent) so members get a memberOf attribute
#   - ou=people / ou=groups, three users, cn=bigip-admins group
#   - Warden-Lab-CA-signed client certs (CN=uid): alice.admin + bob.user valid,
#     carol.expired genuinely expired (notAfter in the past)
# Private keys land in clients/ (gitignored); .crt are public. Kept OUTSIDE certs/ —
# that dir is bind-mounted into openldap, which chowns it on every container start.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
: "${TEST_USER_PW:?set TEST_USER_PW in .env}"
CERTS="${HERE}/../certs"; CLIENTS="${HERE}/../clients"; mkdir -p "$CLIENTS"
# signing below writes $CERTS/ca.srl — reclaim the dir if the openldap container owns it
# (on a FIRST deploy the stack comes up between gen-certs.sh and this script, so the
# chown race hits here, not there)
# shellcheck disable=SC1091
. "${HERE}/lib/certs.sh"
ensure_certs_writable "$CERTS"
# shellcheck disable=SC1091
. "${HERE}/lib/directory.sh"
# shellcheck disable=SC1091
. "${HERE}/lib/ldif.sh"

echo "== 1. enable memberof/refint overlay (ignore 'already exists') =="
docker exec -i openldap ldapmodify -Y EXTERNAL -H ldapi:/// -c \
  < "${HERE}/../ldap/memberof-overlay.ldif" 2>&1 | grep -viE "^SASL|adding|modifying" || true

echo "== 2. add ou=people/ou=groups, users, bigip-admins group =="
ldif_apply "test-users" "${HERE}/../ldap/test-users.ldif"

echo "== 3. issue client certs (CN=uid), signed by the Warden Lab CA =="
# shellcheck disable=SC1091
. "${HERE}/lib/clientcert.sh"

gen_client alice.admin   valid
gen_client bob.user      valid
gen_client carol.expired expired

echo
echo "== verify =="
for u in alice.admin bob.user carol.expired; do
  printf '  %-14s ' "$u"
  openssl x509 -in "$CLIENTS/$u.crt" -noout -enddate | sed 's/notAfter=/notAfter /'
done
echo "  -- openssl chain validation (carol should FAIL: expired) --"
set +e +o pipefail   # carol's verify is EXPECTED to fail; don't let it abort the script
for u in alice.admin bob.user carol.expired; do
  printf '  %-14s ' "$u"; openssl verify -CAfile "$CERTS/ca.crt" "$CLIENTS/$u.crt" 2>&1 | sed "s#$CLIENTS/##"
done
set -e
echo "  -- memberOf (alice+carol in bigip-admins; bob none) --"
for u in alice.admin bob.user carol.expired; do
  printf '  %-14s memberOf=' "$u"
  ldapsearch -x -LLL -H "ldap://${WARDEN_HOST_IP}" -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PW}" \
    -b "uid=$u,ou=people,${BASE_DN}" memberOf 2>/dev/null | grep -i "^memberOf:" | sed 's/memberOf: //' | paste -sd, || echo "(none)"
done
