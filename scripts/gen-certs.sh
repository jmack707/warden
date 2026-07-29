#!/usr/bin/env bash
# T1.2 — generate the lab CA + LDAP server cert. SAN MUST include the address the
# BIG-IP uses to reach the directory (WARDEN_HOST_IP), or LDAPS validation fails closed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
cd "${HERE}/../certs"

# osixia/openldap chowns this bind-mounted dir at startup, so any re-run after the stack
# has been up finds certs/ root-owned. Reclaim it, or fail early with the fix.
if [ ! -w . ] || { [ -e ca.key ] && [ ! -w ca.key ]; }; then
  if command -v sudo >/dev/null 2>&1; then
    echo "==> certs/ not writable (openldap container chowned it) — reclaiming with sudo"
    sudo chown -R "$(id -u):$(id -g)" .
  else
    echo "certs/ is not writable (the openldap container chowns it at startup)." >&2
    echo "Fix as root: chown -R $(id -un) $(pwd)  — then re-run." >&2
    exit 1
  fi
fi

openssl req -x509 -newkey rsa:4096 -nodes -days 365 \
  -keyout ca.key -out ca.crt -subj "/CN=Warden Lab CA"

openssl req -newkey rsa:2048 -nodes \
  -keyout ldap.key -out ldap.csr -subj "/CN=openldap.warden.lab"

printf 'subjectAltName=DNS:openldap.warden.lab,DNS:openldap,IP:%s\n' "${WARDEN_HOST_IP}" > san.cnf

openssl x509 -req -in ldap.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 365 -extfile san.cnf -out ldap.crt

# osixia/openldap runs slapd as uid 911 inside the container; make the key readable
chmod 0644 ldap.crt ca.crt
chmod 0640 ldap.key || true

echo "==> Generated ca.crt, ldap.crt, ldap.key"
openssl x509 -in ldap.crt -noout -ext subjectAltName
