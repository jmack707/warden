#!/usr/bin/env bash
# T1.2 — generate the lab CA + LDAP server cert. SAN MUST include the address the
# BIG-IP uses to reach the directory (LAB_HOST_IP), or LDAPS validation fails closed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
cd "${HERE}/../certs"

openssl req -x509 -newkey rsa:4096 -nodes -days 365 \
  -keyout ca.key -out ca.crt -subj "/CN=PUA Lab CA"

openssl req -newkey rsa:2048 -nodes \
  -keyout ldap.key -out ldap.csr -subj "/CN=openldap.pua.lab"

printf 'subjectAltName=DNS:openldap.pua.lab,DNS:openldap,IP:%s\n' "${LAB_HOST_IP}" > san.cnf

openssl x509 -req -in ldap.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 365 -extfile san.cnf -out ldap.crt

# osixia/openldap runs slapd as uid 911 inside the container; make the key readable
chmod 0644 ldap.crt ca.crt
chmod 0640 ldap.key || true

echo "==> Generated ca.crt, ldap.crt, ldap.key"
openssl x509 -in ldap.crt -noout -ext subjectAltName
