#!/usr/bin/env bash
# Issue Warden-CA-signed client certs + browser .p12 bundles for arbitrary principals.
# Use this when you bring your own directory (WARDEN_DIRECTORY_MODE=external): the client
# PKI stays Warden's (it is the cert-auth trust anchor on the APM front door), while the
# identities themselves live in YOUR AD/LDAP. Nothing is written to the directory.
#
#   scripts/gen-client-certs.sh alice.admin bob.user     # CN must match the login attribute
#
# The CN is what APM extracts and matches against WARDEN_LOGIN_ATTR in your directory, and
# what OpenBao's static role names — so pass exactly the account names (sAMAccountName for
# AD, uid for OpenLDAP/FreeIPA).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
# shellcheck disable=SC1091
. "${HERE}/lib/directory.sh"
[ $# -gt 0 ] || { echo "usage: gen-client-certs.sh <CN> [CN ...]" >&2; exit 2; }

CERTS="${HERE}/../certs"; CLIENTS="${HERE}/../clients"; mkdir -p "$CLIENTS"
[ -f "$CERTS/ca.crt" ] || { echo "no CA yet — run scripts/gen-certs.sh first" >&2; exit 1; }
# shellcheck disable=SC1091
. "${HERE}/lib/certs.sh"
ensure_certs_writable "$CERTS"
# shellcheck disable=SC1091
. "${HERE}/lib/clientcert.sh"

for cn in "$@"; do
  echo "== issuing client cert for ${cn} =="
  gen_client "$cn" valid
  printf '  %-20s ' "$cn"; openssl x509 -in "$CLIENTS/$cn.crt" -noout -enddate | sed 's/notAfter=/notAfter /'
done

echo
echo "Bundles in clients/ (.p12 pass: ${WARDEN_P12_PASS:-warden}). Import with:"
echo "  WARDEN_VM=<user>@<this-host> scripts/import-browser-certs.sh"
echo "Each CN must exist in ${WARDEN_USER_SEARCH_BASE} as ${WARDEN_LOGIN_ATTR}=<CN>,"
echo "and (for admin) be a member of ${WARDEN_ADMIN_GROUP_DN}."
