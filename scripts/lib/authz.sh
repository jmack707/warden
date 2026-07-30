# authz.sh — source AFTER .env and lib/directory.sh. Answers one question in both
# directory modes: "will the BIG-IP actually make anyone an administrator?"
#
# It exists because the failure it detects is silent. The BIG-IP evaluates remote-role
# against the attributes a DEFAULT LDAP search returns for the account it just
# authenticated — it never requests attributes by name. An attribute the directory hands
# over only on request (notably memberOf from OpenLDAP's memberof overlay, which is
# operational) is invisible to it, so every user authenticates successfully and lands on
# the default read-only role with nothing logged as wrong.
#
# Callers may define ok/bad/note for coloured output (preflight-directory.sh does);
# plain fallbacks are used otherwise.

declare -F ok   >/dev/null || ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
declare -F bad  >/dev/null || bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
declare -F note >/dev/null || note() { printf '       %s\n' "$*"; }

# warden_warn_unused_admin_group — config-level only, no directory access.
# Flags the case where an admin group was configured but the rule the BIG-IP evaluates
# does not mention it, so the group has no bearing on who becomes an administrator.
# Returns 0 always: this is advice, not a failure.
warden_warn_unused_admin_group() {
  [ "${WARDEN_ADMIN_GROUP_DN_EXPLICIT:-0}" = 1 ] || return 0
  case "$WARDEN_ADMIN_ROLE_ATTRIBUTE" in *"$WARDEN_ADMIN_GROUP_DN"*) return 0;; esac
  echo
  echo "  NOTE: WARDEN_ADMIN_GROUP_DN is set to"
  echo "          ${WARDEN_ADMIN_GROUP_DN}"
  echo "        but the BIG-IP decides on  ${WARDEN_ADMIN_ROLE_ATTRIBUTE}, which does not"
  echo "        reference that group — so membership in it grants nothing. That is normal in"
  echo "        bundled mode (the seeded employeeType stamp decides). If you meant the group"
  echo "        to be the deciding factor, set:"
  echo "          WARDEN_ADMIN_ROLE_ATTRIBUTE=memberOf=${WARDEN_ADMIN_GROUP_DN}"
  echo "        and confirm memberOf survives a default search — see docs/directory.md."
  echo
}

# warden_check_admin_mapping <ldap-uri> [bind-dn] [bind-pw]
# Probes the directory exactly as the BIG-IP will: as the read-only search bind, over a
# default search of the PRIVILEGED subtree (the accounts the BIG-IP binds and evaluates —
# not the human identity entries). Binding as that account also catches an ACL that hides
# the attribute from it, which looks identical from the BIG-IP's side.
# Returns 0 when at least one privileged account would be granted Administrator.
warden_check_admin_mapping() {
  local uri="$1" bdn="${2:-$WARDEN_BIND_DN}" bpw="${3:-$BIND_PW}" probe holders
  probe="$(ldapsearch -x -LLL -H "$uri" -D "$bdn" -w "$bpw" \
           -b "${WARDEN_PRIV_SEARCH_BASE}" "(${WARDEN_LOGIN_ATTR}=*)" 2>/dev/null)" || true

  if [ -z "$probe" ]; then
    bad "no privileged accounts are visible under ${WARDEN_PRIV_SEARCH_BASE}"
    note "as ${bdn} — check the subtree and that bind's read access"
    return 1
  fi

  if grep -qiE "^${WARDEN_ADMIN_ROLE_ATTR}:" <<<"$probe"; then
    holders="$(grep -icE "^${WARDEN_ADMIN_ROLE_ATTR}: *${WARDEN_ADMIN_ROLE_VALUE}$" <<<"$probe")"
    if [ "$holders" -gt 0 ]; then
      ok "${WARDEN_ADMIN_ROLE_ATTR} is returned by a default search — ${holders} privileged account(s) match ${WARDEN_ADMIN_ROLE_VALUE}"
      return 0
    fi
    bad "no privileged account carries ${WARDEN_ADMIN_ROLE_ATTRIBUTE}"
    note "every user would authenticate and land read-only"
    note "→ add the accounts under ${WARDEN_PRIV_SEARCH_BASE} to the admin group, or stamp the attribute on them"
    return 1
  fi

  bad "${WARDEN_ADMIN_ROLE_ATTR} is NOT returned by a default search of ${WARDEN_PRIV_SEARCH_BASE}"
  note "the BIG-IP would silently grant read-only (guest) to EVERY user"
  if [ "$(printf '%s' "$WARDEN_ADMIN_ROLE_ATTR" | tr 'A-Z' 'a-z')" = memberof ] &&
     ldapsearch -x -LLL -H "$uri" -D "$bdn" -w "$bpw" \
       -b "${WARDEN_PRIV_SEARCH_BASE}" "(${WARDEN_LOGIN_ATTR}=*)" memberOf 2>/dev/null | grep -qi '^memberOf:'; then
    note "memberOf EXISTS but only when requested by name — it is operational here"
    note "(OpenLDAP memberof overlay). The BIG-IP cannot use it."
    note "→ map on a stored attribute instead, e.g."
    note "  WARDEN_ADMIN_ROLE_ATTRIBUTE=employeeType=warden-admins"
  else
    note "→ stamp ${WARDEN_ADMIN_ROLE_ATTR} on the privileged accounts, or map on another attribute"
  fi
  return 1
}
