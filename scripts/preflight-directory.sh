#!/usr/bin/env bash
# Read-only pre-flight for an EXTERNAL directory (AD / FreeIPA / any LDAP). Proves Warden
# can use it BEFORE anything is changed on the BIG-IP. Writes nothing, anywhere.
#
# Checks, in order:
#   1. LDAPS reachable and its cert validates against WARDEN_LDAP_CA_FILE
#   2. the read-only bind (WARDEN_BIND_DN / BIND_PW) works and can search identities
#   3. the admin group exists, and how membership is expressed there
#   4. the privileged subtree exists (where OpenBao will rotate passwords)
#   5. the privileged bind (WARDEN_DIR_ADMIN_DN) works
# Each failure prints the exact .env key to fix. Exit 0 = safe to deploy.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
# shellcheck disable=SC1091
. "${HERE}/lib/directory.sh"
# shellcheck disable=SC1091
. "${HERE}/lib/authz.sh"

fails=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fails=$((fails+1)); }
note() { printf '       %s\n' "$*"; }

case "${WARDEN_LDAP_CA_FILE}" in /*) CAF="${WARDEN_LDAP_CA_FILE}";; *) CAF="${HERE}/../${WARDEN_LDAP_CA_FILE}";; esac
URI="ldaps://${WARDEN_LDAP_HOST}:${WARDEN_LDAPS_PORT}"
export LDAPTLS_CACERT="$CAF"

echo "== directory pre-flight: ${URI} =="
warden_directory_summary

echo "== 1. LDAPS + certificate chain =="
if [ ! -f "$CAF" ]; then
  bad "CA PEM not found at $CAF  → set WARDEN_LDAP_CA_FILE"
elif out="$(echo | openssl s_client -connect "${WARDEN_LDAP_HOST}:${WARDEN_LDAPS_PORT}" -CAfile "$CAF" 2>&1)"; then
  if grep -q "Verify return code: 0 (ok)" <<<"$out"; then
    ok "LDAPS cert validates against $(basename "$CAF")"
  else
    bad "LDAPS cert does NOT validate: $(grep -m1 'Verify return code' <<<"$out" | sed 's/^ *//')"
    note "the BIG-IP will fail the same way — export the issuing CA of your LDAPS cert"
    note "subject: $(grep -m1 '^subject=' <<<"$out")"
  fi
else
  bad "cannot reach ${WARDEN_LDAP_HOST}:${WARDEN_LDAPS_PORT}  → check WARDEN_LDAP_HOST/WARDEN_LDAPS_PORT + firewall"
fi

echo "== 2. read-only bind + identity search =="
if ent="$(ldapsearch -x -LLL -H "$URI" -D "${WARDEN_BIND_DN}" -w "${BIND_PW}" \
          -b "${WARDEN_USER_SEARCH_BASE}" -s base dn 2>&1)"; then
  ok "bind as ${WARDEN_BIND_DN} + read ${WARDEN_USER_SEARCH_BASE}"
  n="$(ldapsearch -x -LLL -H "$URI" -D "${WARDEN_BIND_DN}" -w "${BIND_PW}" \
       -b "${WARDEN_USER_SEARCH_BASE}" "(${WARDEN_LOGIN_ATTR}=*)" dn 2>/dev/null | grep -c '^dn:')"
  note "${n} entries carry ${WARDEN_LOGIN_ATTR} under the identity base"
  [ "$n" -gt 0 ] || bad "no entries with ${WARDEN_LOGIN_ATTR}  → wrong WARDEN_LOGIN_ATTR or WARDEN_USER_SEARCH_BASE?"
else
  bad "read-only bind/search failed  → check WARDEN_BIND_DN, BIND_PW, WARDEN_USER_SEARCH_BASE"
  note "$(head -2 <<<"$ent" | tr '\n' ' ')"
fi

echo "== 3. the BIG-IP admin group =="
if grp="$(ldapsearch -x -LLL -H "$URI" -D "${WARDEN_BIND_DN}" -w "${BIND_PW}" \
          -b "${WARDEN_ADMIN_GROUP_DN}" -s base 2>&1)"; then
  ok "admin group exists: ${WARDEN_ADMIN_GROUP_DN}"
  members="$(grep -ciE '^(member|memberUid|uniqueMember):' <<<"$grp")"
  note "${members} member attribute(s) on the group entry"
  [ "$members" -gt 0 ] || note "group is empty — nobody will get Administrator until you add members"
  note "BIG-IP will map: ${WARDEN_ADMIN_ROLE_ATTRIBUTE}"
  warden_check_admin_mapping "$URI" || fails=$((fails+1))
else
  bad "admin group not found  → set WARDEN_ADMIN_GROUP_DN to an existing group DN"
  note "$(head -2 <<<"$grp" | tr '\n' ' ')"
fi

echo "== 4/5. privileged subtree + password-reset bind =="
if ldapsearch -x -LLL -H "$URI" -D "${WARDEN_DIR_ADMIN_DN}" -w "${WARDEN_DIR_ADMIN_PW}" \
     -b "${WARDEN_PRIV_SEARCH_BASE}" -s base dn >/dev/null 2>&1; then
  ok "bind as ${WARDEN_DIR_ADMIN_DN} + read ${WARDEN_PRIV_SEARCH_BASE}"
  note "OpenBao will RESET PASSWORDS on accounts under here — keep it a dedicated OU"
  note "(this pre-flight does not test the write; the first rotation will)"
else
  bad "privileged bind/subtree failed  → check WARDEN_DIR_ADMIN_DN/PW, WARDEN_PRIV_SEARCH_BASE"
fi

echo
if [ "$fails" -eq 0 ]; then echo "== pre-flight PASSED — safe to deploy =="; exit 0; fi
echo "== pre-flight FAILED (${fails} problem(s)) — fix .env and re-run =="; exit 1
