#!/usr/bin/env bash
# Warden — one-command demo deploy. Reads .env, stands up the OSS stack, configures the
# directory + OpenBao, and builds the APM front door on the target BIG-IP(s).
#
# Prereqs: docker + the compose plugin (docker compose), openssl/ldap-utils/jq on this host, and REST reach to
# the BIG-IP management address(es) in .env. Run from the repo root:  ./deploy.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"

# preflight: fail before touching anything if a prereq binary is missing
missing=""
for c in openssl ldapadd ldapmodify jq envsubst docker; do
  command -v "$c" >/dev/null || missing="$missing $c"
done
{ command -v docker >/dev/null && docker compose version >/dev/null 2>&1; } || missing="$missing docker-compose-plugin"
[ -z "$missing" ] || {
  echo "missing prereqs:$missing" >&2
  echo "on Debian/Ubuntu: sudo apt-get install -y ldap-utils jq gettext-base openssl  (docker + compose plugin per docs/install.md)" >&2
  exit 1
}

[ -f .env ] || { echo "no .env — copy .env.example to .env and fill in the <angle-bracket> values" >&2; exit 1; }
set -a; . ./.env; set +a

# fail early on unfilled placeholders
miss=0
for v in WARDEN_HOST_IP BASE_DN LDAP_ADMIN_PW BIND_PW BIGIP_MGMT BIGIP_PASS WARDEN_APM_VIP; do
  val="${!v:-}"
  case "$val" in ""|*"<"*">"*) echo "  .env: set $v"; miss=1;; esac
done
[ "$miss" = 0 ] || { echo "fill the values above in .env, then re-run" >&2; exit 1; }
PEER_NOTE="single standalone BIG-IP"; [ -n "${WARDEN_BIGIP_B_MGMT:-}" ] && PEER_NOTE="HA pair (peer ${WARDEN_BIGIP_B_MGMT})"

echo "== Warden deploy — target ${BIGIP_MGMT} (${PEER_NOTE}), VIP ${WARDEN_APM_VIP} =="

echo "== 1/7 TLS material (CA + LDAPS server cert) =="
./scripts/gen-certs.sh

echo "== 2/7 bring up OpenBao + OpenLDAP =="
docker compose up -d
sleep 5

echo "== 3/7 seed the directory + bind ACL =="
envsubst < ldap/seed.ldif | ldapadd -x -H "ldap://${WARDEN_HOST_IP}" -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PW}" -c 2>&1 | grep -viE "already exists|^adding" || true
docker exec -i openldap ldapmodify -Y EXTERNAL -H ldapi:/// < ldap/acl-bigip-bind.ldif 2>&1 | grep -viE "^modifying|^SASL" || true

echo "== 4/7 configure OpenBao (LDAP secrets engine + audit) =="
./scripts/configure-openbao.sh

echo "== 5/7 test principals + client certs, static roles for injection =="
./scripts/gen-test-users.sh "${BASE_DN}" seed
# ou=users privileged ACCESS accounts (alice=admin via employeeType, bob=non-admin); OpenBao
# rotates their password and the BIG-IP binds it. Distinct from the ou=people identities above.
for ldif in ldap/warden-users.ldif ldap/remote-roles.ldif; do
  ldapadd -x -c -H "ldap://${WARDEN_HOST_IP}" -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PW}" -f "$ldif" 2>&1 | grep -viE "^adding|already exists" || true
done
./scripts/configure-openbao-static.sh alice.admin bob.user
./scripts/configure-openbao-phase2.sh   # scoped token policy for the APM fetch

echo "== 6/7 BIG-IP auth (LDAPS system-auth + remote-role) =="
BIGIP_PASS="$BIGIP_PASS" ./bigip/phase1-target-rest.sh

echo "== 7/7 APM front door (cert auth + credential injection + webtop) =="
./bigip/run-apm-build.sh

cat <<EOF

== done ==
Verify:
  ./scripts/validate-phase1.sh          # credential core (no BIG-IP)
  # browser: import certs, then https://${WARDEN_APM_VIP}/ and pick a client cert
  #   docs/operations/runbooks/browser-verify.md
EOF
