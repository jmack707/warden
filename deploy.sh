#!/usr/bin/env bash
# Warden — one-command demo deploy. Reads .env, stands up the OSS stack, configures the
# directory + OpenBao, and builds the APM front door on the target BIG-IP(s).
#
# Prereqs: docker + the compose plugin (docker compose), openssl/ldap-utils/jq on this host, and REST reach to
# the BIG-IP management address(es) in .env. Run from the repo root:
#   ./deploy.sh                 everything (default)
#   ./deploy.sh --stack         the OSS core only (certs, containers, directory, OpenBao)
#                               — no BIG-IP is contacted, so BIGIP_* need not be set
#   ./deploy.sh --bigip         the BIG-IP config only (assumes the stack is already up)
# Mirrors teardown.sh, which takes the same three forms.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"

DO_STACK=0; DO_BIGIP=0
while [ $# -gt 0 ]; do case "$1" in
  --stack) DO_STACK=1;; --bigip) DO_BIGIP=1;; --all) DO_STACK=1; DO_BIGIP=1;;
  -h|--help) sed -n '2,12p' "$0"; exit 0;;
  *) echo "unknown arg: $1 (see --help)" >&2; exit 2;;
esac; shift; done
[ $((DO_STACK+DO_BIGIP)) -gt 0 ] || { DO_STACK=1; DO_BIGIP=1; }

# preflight: fail before touching anything if a prereq binary is missing
missing=""
for c in openssl ldapadd ldapmodify jq envsubst docker; do
  command -v "$c" >/dev/null || missing="$missing $c"
done
# Compose is always invoked as `docker compose` (v2 plugin). The standalone v1
# `docker-compose` binary is EOL and unsupported here.
COMPOSE_MISSING=0
{ command -v docker >/dev/null && docker compose version >/dev/null 2>&1; } || COMPOSE_MISSING=1
[ "$COMPOSE_MISSING" = 0 ] || missing="$missing docker-compose-plugin"
[ -z "$missing" ] || {
  echo "missing prereqs:$missing" >&2
  echo "on Debian/Ubuntu: sudo apt-get install -y ldap-utils jq gettext-base openssl" >&2
  if [ "$COMPOSE_MISSING" = 1 ]; then
    echo "compose: this repo uses the v2 plugin form 'docker compose'." >&2
    if command -v docker-compose >/dev/null 2>&1; then
      echo "  found a standalone 'docker-compose' ($(docker-compose version --short 2>/dev/null || echo '?')) but no plugin." >&2
      echo "  install it:  sudo apt-get install -y docker-compose-v2   (or alias docker-compose -> docker compose)" >&2
    else
      echo "  install it:  sudo apt-get install -y docker-compose-v2   (see docs/install.md)" >&2
    fi
  fi
  exit 1
}

[ -f .env ] || { echo "no .env — copy .env.example to .env and fill in the <angle-bracket> values" >&2; exit 1; }
set -a; . ./.env; set +a
# shellcheck disable=SC1091
. ./scripts/lib/directory.sh
# shellcheck disable=SC1091
. ./scripts/lib/ldif.sh
# shellcheck disable=SC1091
. ./scripts/lib/authz.sh

# fail early on unfilled placeholders
miss=0
REQ="WARDEN_HOST_IP BASE_DN BIND_PW"
[ $DO_BIGIP = 1 ] && REQ="$REQ BIGIP_MGMT BIGIP_PASS WARDEN_APM_VIP"
if warden_is_bundled; then
  REQ="$REQ LDAP_ADMIN_PW TEST_USER_PW"
else
  REQ="$REQ WARDEN_LDAP_HOST WARDEN_DIR_ADMIN_DN WARDEN_DIR_ADMIN_PW WARDEN_LDAP_CA_FILE WARDEN_ADMIN_GROUP_DN"
fi
for v in $REQ; do
  val="${!v:-}"
  case "$val" in ""|*"<"*">"*) echo "  .env: set $v"; miss=1;; esac
done
[ "$miss" = 0 ] || { echo "fill the values above in .env, then re-run" >&2; exit 1; }
PEER_NOTE="single standalone BIG-IP"; [ -n "${WARDEN_BIGIP_B_MGMT:-}" ] && PEER_NOTE="HA pair (peer ${WARDEN_BIGIP_B_MGMT})"

if [ $DO_BIGIP = 1 ]; then
  echo "== Warden deploy — target ${BIGIP_MGMT} (${PEER_NOTE}), VIP ${WARDEN_APM_VIP} =="
else
  echo "== Warden deploy — OSS stack only (no BIG-IP will be contacted) =="
fi
warden_directory_summary
warden_warn_unused_admin_group

if [ $DO_STACK = 1 ]; then
echo "== 1/7 TLS material (client-cert CA; LDAPS server cert when bundled) =="
./scripts/gen-certs.sh

echo "== 2/7 bring up OpenBao${WARDEN_BUNDLED_NOTE:- + OpenLDAP} =="
# note whether openldap predates the certs we just regenerated: slapd only reads TLS
# material at startup, so it must be restarted before the BIG-IP steps — but NOT here:
# the container chowns certs/ on start, and steps 3-5 still sign with certs/ca.key
LDAP_NEEDS_RESTART=""
if warden_is_bundled; then
  LDAP_NEEDS_RESTART="$(docker ps -q -f name='^openldap$')"
  docker compose --profile bundled up -d
else
  docker compose up -d          # openbao only; your directory is already running
fi
# poll instead of sleeping: on a fresh volume the container's first-run bootstrap takes
# much longer than a fixed sleep, and seeding into a half-initialized slapd fails
warden_is_bundled && wait_for_ldap 90

if warden_is_bundled; then
  echo "== 3/7 seed the bundled directory + bind ACL =="
  ldif_apply "seed" ldap/seed.ldif
  envsubst < ldap/acl-bigip-bind.ldif | docker exec -i openldap ldapmodify -Y EXTERNAL -H ldapi:/// 2>&1 | grep -viE "^modifying|^SASL" || true
else
  echo "== 3/7 external directory (${WARDEN_LDAP_HOST}) — nothing seeded, nothing modified =="
  echo "   identities:  ${WARDEN_USER_SEARCH_BASE}"
  echo "   privileged:  ${WARDEN_PRIV_SEARCH_BASE}   (OpenBao rotates passwords HERE)"
  echo "   admin group: ${WARDEN_ADMIN_GROUP_DN}"
  ./scripts/preflight-directory.sh || { echo "directory pre-flight failed — fix the above, then re-run" >&2; exit 1; }
fi

echo "== 4/7 configure OpenBao (LDAP secrets engine + audit) =="
./scripts/configure-openbao.sh

echo "== 5/7 client certs + static roles for injection =="
if warden_is_bundled; then
  ./scripts/gen-test-users.sh "${BASE_DN}" seed
  # privileged ACCESS accounts (alice=admin via the role stamp, bob=non-admin); OpenBao
  # rotates their password and the BIG-IP binds it. Distinct from the identity entries.
  for ldif in ldap/warden-users.ldif ldap/remote-roles.ldif ldap/admin-group.ldif; do
    ldif_apply "${ldif##*/}" "$ldif"
  done
  ./scripts/configure-openbao-static.sh alice.admin bob.user
else
  # external: Warden creates no accounts. Issue client certs for the principals you name
  # in WARDEN_PRINCIPALS, and take over the password of each matching privileged account.
  : "${WARDEN_PRINCIPALS:?external mode: set WARDEN_PRINCIPALS to the CNs to issue certs + static roles for (space-separated)}"
  ./scripts/gen-client-certs.sh $WARDEN_PRINCIPALS
  # shellcheck disable=SC2086
  ./scripts/configure-openbao-static.sh $WARDEN_PRINCIPALS
fi
./scripts/configure-openbao-phase2.sh   # scoped token policy for the APM fetch

if warden_is_bundled; then
  # Probe as the BIG-IP's own read-only bind, over a default search — the exact conditions
  # remote-role will face. This is what external mode gets from preflight-directory.sh.
  echo "== check: will the BIG-IP grant Administrator to anyone? =="
  if ! warden_check_admin_mapping "ldap://${WARDEN_LDAP_HOST}"; then
    echo
    echo "  ^ the deploy continues, but every operator would land READ-ONLY on ${BIGIP_MGMT}."
    echo "    Fix the mapping and re-run:  ./deploy.sh --bigip"
    echo
  fi
fi

# all local cert signing is done — now slapd can pick up the regenerated TLS material
# (the restart chowns certs/ to the container user; gen-certs.sh reclaims it next run)
if [ -n "$LDAP_NEEDS_RESTART" ]; then
  echo "== restart openldap to load the regenerated certs =="
  docker compose restart openldap
  wait_for_ldap 90
fi
fi   # end DO_STACK

if [ $DO_BIGIP = 0 ]; then
  cat <<EOF

== stack up (no BIG-IP contacted) ==
Verify:  ./scripts/validate-phase1.sh
Then configure a BIG-IP with:  ./deploy.sh --bigip
EOF
  exit 0
fi

echo "== 6/7 BIG-IP auth (LDAPS system-auth + remote-role: ${WARDEN_ADMIN_ROLE_ATTRIBUTE}) =="
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
