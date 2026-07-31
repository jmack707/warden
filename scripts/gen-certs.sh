#!/usr/bin/env bash
# T1.2 — generate the lab CA + LDAP server cert. SAN MUST include the address the
# BIG-IP uses to reach the directory (WARDEN_HOST_IP), or LDAPS validation fails closed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
# shellcheck disable=SC1091
. "${HERE}/lib/directory.sh"
mkdir -p "${HERE}/../certs"   # gitignored — absent on a fresh clone
cd "${HERE}/../certs"

# shellcheck disable=SC1091
. "${HERE}/lib/certs.sh"
ensure_certs_writable .

# REUSE an existing CA. deploy.sh is meant to be re-runnable, but minting a fresh CA every
# run silently invalidates every issued client cert and every browser import (and the trust
# anchor on the BIG-IP). Set WARDEN_REGEN_CA=1 to deliberately roll it — then re-issue the
# client certs and re-import them.
if [ -s ca.crt ] && [ -s ca.key ] && [ "${WARDEN_REGEN_CA:-0}" != 1 ]; then
  echo "==> reusing existing CA ($(openssl x509 -in ca.crt -noout -subject | sed 's/^subject=//'))"
  echo "    (WARDEN_REGEN_CA=1 to mint a new one — invalidates issued client certs)"
else
  [ -s ca.crt ] && echo "==> WARDEN_REGEN_CA=1: minting a NEW CA (issued client certs become invalid)"
  openssl req -x509 -newkey rsa:4096 -nodes -days 365 \
    -keyout ca.key -out ca.crt -subj "/CN=${WARDEN_CA_CN:-Warden Lab CA}"
fi

# The client-cert CA above is ALWAYS needed (it signs the client certs the APM front door
# trusts). The LDAPS server cert below is only for the BUNDLED OpenLDAP — with your own
# directory, it already has its own cert and you point WARDEN_LDAP_CA_FILE at its CA.
if ! warden_is_bundled; then
  chmod 0644 ca.crt
  echo "==> Generated ca.crt (client-cert CA). External directory: skipping LDAPS server cert;"
  echo "    the BIG-IP will validate LDAPS against ${WARDEN_LDAP_CA_FILE}."
  exit 0
fi

openssl req -newkey rsa:2048 -nodes \
  -keyout ldap.key -out ldap.csr -subj "/CN=openldap.${WARDEN_DOMAIN:-warden.lab}"

printf 'subjectAltName=DNS:openldap.%s,DNS:openldap,IP:%s\n' "${WARDEN_DOMAIN:-warden.lab}" "${WARDEN_LDAP_HOST}" > san.cnf

openssl x509 -req -in ldap.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 365 -extfile san.cnf -out ldap.crt

# osixia/openldap runs slapd as uid 911 inside the container; make the key readable
chmod 0644 ldap.crt ca.crt
chmod 0640 ldap.key || true

echo "==> Generated ca.crt, ldap.crt, ldap.key"
openssl x509 -in ldap.crt -noout -ext subjectAltName
