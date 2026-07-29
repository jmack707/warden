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

echo "== 1. enable memberof/refint overlay (ignore 'already exists') =="
docker exec -i openldap ldapmodify -Y EXTERNAL -H ldapi:/// -c \
  < "${HERE}/../ldap/memberof-overlay.ldif" 2>&1 | grep -viE "^SASL|adding|modifying" || true

echo "== 2. add ou=people/ou=groups, users, bigip-admins group =="
envsubst < "${HERE}/../ldap/test-users.ldif" \
  | ldapadd -x -H "ldap://${WARDEN_HOST_IP}" -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PW}" -c 2>&1 \
  | grep -viE "^adding" || true

echo "== 3. issue client certs (CN=uid), signed by the Warden Lab CA =="
gen_client() {  # gen_client <uid> <valid|expired>
  local uid="$1" mode="$2"
  openssl req -newkey rsa:2048 -nodes -keyout "$CLIENTS/$uid.key" -out "$CLIENTS/$uid.csr" \
    -subj "/CN=$uid" 2>/dev/null || { echo "ERROR: keygen/CSR failed for $uid" >&2; exit 1; }
  cat > "$CLIENTS/$uid.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectAltName=email:$uid@warden.lab
EOF
  if [ "$mode" = expired ]; then
    # valid window entirely in the past -> expired now. x509 grew -not_before/-not_after
    # in OpenSSL 3.4; on older builds (Ubuntu 22.04 = 3.0) back-date via `openssl ca`.
    if openssl x509 -help 2>&1 | grep -q not_before; then
      openssl x509 -req -in "$CLIENTS/$uid.csr" -CA "$CERTS/ca.crt" -CAkey "$CERTS/ca.key" -CAcreateserial \
        -not_before 20240101000000Z -not_after 20241231235959Z \
        -extfile "$CLIENTS/$uid.ext" -out "$CLIENTS/$uid.crt"
    else
      local cadir; cadir="$(mktemp -d)"
      touch "$cadir/index.txt"; echo 01 > "$cadir/serial"
      printf '[ca]\ndefault_ca = warden\n[warden]\ndatabase = %s/index.txt\nserial = %s/serial\nnew_certs_dir = %s\ndefault_md = sha256\npolicy = pol\nemail_in_dn = no\n[pol]\ncommonName = supplied\n' \
        "$cadir" "$cadir" "$cadir" > "$cadir/ca.cnf"
      { echo "[ext]"; cat "$CLIENTS/$uid.ext"; } > "$cadir/ext.cnf"
      local caout
      caout="$(openssl ca -batch -config "$cadir/ca.cnf" -keyfile "$CERTS/ca.key" -cert "$CERTS/ca.crt" \
        -startdate 20240101000000Z -enddate 20241231235959Z \
        -in "$CLIENTS/$uid.csr" -extfile "$cadir/ext.cnf" -extensions ext -notext \
        -out "$CLIENTS/$uid.crt" 2>&1)" \
        || { echo "$caout" >&2; echo "ERROR: expired-cert issue failed for $uid" >&2; rm -rf "$cadir"; exit 1; }
      rm -rf "$cadir"
    fi
  else
    openssl x509 -req -in "$CLIENTS/$uid.csr" -CA "$CERTS/ca.crt" -CAkey "$CERTS/ca.key" -CAcreateserial \
      -days 365 -extfile "$CLIENTS/$uid.ext" -out "$CLIENTS/$uid.crt"
  fi
  chmod 0644 "$CLIENTS/$uid.crt"; chmod 0600 "$CLIENTS/$uid.key"
  # PKCS12 bundle for browser import (password: $WARDEN_P12_PASS) — see scripts/import-browser-certs.sh
  openssl pkcs12 -export -inkey "$CLIENTS/$uid.key" -in "$CLIENTS/$uid.crt" \
    -certfile "$CERTS/ca.crt" -name "Warden $uid" -out "$CLIENTS/$uid.p12" \
    -passout pass:"${WARDEN_P12_PASS:-warden}" 2>/dev/null \
    || { echo "ERROR: p12 bundle failed for $uid" >&2; exit 1; }
  chmod 0600 "$CLIENTS/$uid.p12"
}
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
