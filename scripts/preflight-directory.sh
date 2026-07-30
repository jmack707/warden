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
  # CRITICAL: the BIG-IP evaluates remote-role against the attributes a DEFAULT search
  # returns for the account it just authenticated — it does not request extra attributes.
  # So the mapping attribute must come back WITHOUT being asked for by name. OpenLDAP's
  # memberof overlay makes memberOf *operational* (returned only on request), so a
  # memberOf mapping silently degrades every user to the default role there. AD and
  # 389DS/FreeIPA store it as a real attribute and are fine.
  # Search the PRIVILEGED subtree: the BIG-IP binds those accounts, so that is the entry
  # whose attributes decide the role.
  probe="$(ldapsearch -x -LLL -H "$URI" -D "${WARDEN_BIND_DN}" -w "${BIND_PW}" \
           -b "${WARDEN_PRIV_SEARCH_BASE}" "(${WARDEN_LOGIN_ATTR}=*)" 2>/dev/null)"
  if grep -qiE "^${WARDEN_ADMIN_ROLE_ATTR}:" <<<"$probe"; then
    holders="$(grep -icE "^${WARDEN_ADMIN_ROLE_ATTR}: *${WARDEN_ADMIN_ROLE_VALUE}$" <<<"$probe")"
    ok "${WARDEN_ADMIN_ROLE_ATTR} is returned by a default search — ${holders} privileged account(s) match the admin value"
    [ "$holders" -gt 0 ] || { bad "no privileged account carries ${WARDEN_ADMIN_ROLE_ATTRIBUTE}"
      note "the BIG-IP would grant read-only to everyone → add the accounts under ${WARDEN_PRIV_SEARCH_BASE} to the group"; }
  else
    bad "${WARDEN_ADMIN_ROLE_ATTR} is NOT returned by a default search of ${WARDEN_PRIV_SEARCH_BASE}"
    note "the BIG-IP would silently grant read-only (guest) to EVERY user"
    if [ "$(printf '%s' "$WARDEN_ADMIN_ROLE_ATTR" | tr 'A-Z' 'a-z')" = memberof ]; then
      if ldapsearch -x -LLL -H "$URI" -D "${WARDEN_BIND_DN}" -w "${BIND_PW}" \
           -b "${WARDEN_PRIV_SEARCH_BASE}" "(${WARDEN_LOGIN_ATTR}=*)" memberOf 2>/dev/null | grep -qi '^memberOf:'; then
        note "memberOf EXISTS but only when requested by name — it is an operational"
        note "attribute here (OpenLDAP memberof overlay). The BIG-IP cannot use it."
        note "→ set WARDEN_ADMIN_ROLE_ATTRIBUTE to a real attribute your accounts carry,"
        note "  e.g. WARDEN_ADMIN_ROLE_ATTRIBUTE=employeeType=warden-admins"
      else
        note "→ add the privileged accounts to ${WARDEN_ADMIN_GROUP_DN}, or map on another attribute"
      fi
    else
      note "→ stamp ${WARDEN_ADMIN_ROLE_ATTR} on the privileged accounts, or pick another attribute"
    fi
  fi
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
