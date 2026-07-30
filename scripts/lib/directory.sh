# directory.sh — source this AFTER .env. Single source of truth for "which directory does
# Warden use, and how is the BIG-IP admin group expressed there". Every consumer (OpenBao
# config, BIG-IP system-auth, APM AAA, validation) reads these instead of hardcoding DNs.
#
# Two modes:
#   bundled  (default) — Warden runs its own OpenLDAP in compose and seeds it. Zero config.
#   external           — you bring AD / FreeIPA / any LDAP. Warden creates NOTHING in it;
#                        it only reads identities and (for the injection flow) manages the
#                        privileged accounts you point it at.
#
# Warden uses the directory for TWO distinct things — keep them straight when pointing at
# your own:
#   1. IDENTITY  (WARDEN_USER_SEARCH_BASE) — who the cert holder is. Read-only.
#   2. PRIVILEGED ACCOUNTS (WARDEN_PRIV_SEARCH_BASE) — the accounts OpenBao rotates and the
#      BIG-IP binds as. OpenBao needs WRITE (password reset) on these. Point this at a
#      dedicated OU, never at your general user population.

WARDEN_DIRECTORY_MODE="${WARDEN_DIRECTORY_MODE:-bundled}"
case "$WARDEN_DIRECTORY_MODE" in
  bundled|external) ;;
  *) echo "WARDEN_DIRECTORY_MODE must be 'bundled' or 'external' (got '$WARDEN_DIRECTORY_MODE')" >&2; return 1 2>/dev/null || exit 1;;
esac
warden_is_bundled() { [ "$WARDEN_DIRECTORY_MODE" = bundled ]; }

: "${BASE_DN:?set BASE_DN in .env}"

# ─── where the directory lives ───────────────────────────────────────────────
if warden_is_bundled; then
  WARDEN_LDAP_HOST="${WARDEN_LDAP_HOST:-${WARDEN_HOST_IP:?set WARDEN_HOST_IP in .env}}"
else
  : "${WARDEN_LDAP_HOST:?external mode: set WARDEN_LDAP_HOST to your AD/LDAP address}"
fi
WARDEN_LDAP_PORT="${WARDEN_LDAP_PORT:-389}"
WARDEN_LDAPS_PORT="${WARDEN_LDAPS_PORT:-636}"

# openldap | ad — picked up by OpenBao's LDAP secrets engine (AD resets unicodePwd
# instead of userPassword) and by the login-attribute default below.
WARDEN_LDAP_SCHEMA="${WARDEN_LDAP_SCHEMA:-openldap}"

# ─── binds ───────────────────────────────────────────────────────────────────
# read-only bind the BIG-IP uses to search identities
WARDEN_BIND_DN="${WARDEN_BIND_DN:-cn=bigip-bind,ou=svc,${BASE_DN}}"
# privileged bind OpenBao uses to RESET passwords on the privileged accounts
if warden_is_bundled; then
  WARDEN_DIR_ADMIN_DN="${WARDEN_DIR_ADMIN_DN:-cn=admin,${BASE_DN}}"
  WARDEN_DIR_ADMIN_PW="${WARDEN_DIR_ADMIN_PW:-${LDAP_ADMIN_PW:?set LDAP_ADMIN_PW in .env}}"
else
  # NOTE: no apostrophes in :? messages — bash quote-processes the word and an unpaired
  # quote makes the whole file unparseable.
  : "${WARDEN_DIR_ADMIN_DN:?external mode: set WARDEN_DIR_ADMIN_DN (an account that may reset passwords on the privileged OU)}"
  : "${WARDEN_DIR_ADMIN_PW:?external mode: set WARDEN_DIR_ADMIN_PW}"
fi

# ─── subtrees ────────────────────────────────────────────────────────────────
WARDEN_USER_SEARCH_BASE="${WARDEN_USER_SEARCH_BASE:-ou=people,${BASE_DN}}"
WARDEN_PRIV_SEARCH_BASE="${WARDEN_PRIV_SEARCH_BASE:-ou=users,${BASE_DN}}"

# login attribute: what the cert CN is matched against, and what the BIG-IP logs in as
if [ "$WARDEN_LDAP_SCHEMA" = ad ]; then
  WARDEN_LOGIN_ATTR="${WARDEN_LOGIN_ATTR:-sAMAccountName}"
else
  WARDEN_LOGIN_ATTR="${WARDEN_LOGIN_ATTR:-uid}"
fi

# The RDN attribute of a privileged account's DN. Distinct from WARDEN_LOGIN_ATTR: AD
# users log in as sAMAccountName but their DN is CN=<display name>,OU=... So with AD, the
# name you pass to configure-openbao-static.sh must match the DN's CN component (or set
# WARDEN_PRIV_DN_ATTR/pass explicit DNs). OpenLDAP/FreeIPA use uid for both.
if [ "$WARDEN_LDAP_SCHEMA" = ad ]; then
  WARDEN_PRIV_DN_ATTR="${WARDEN_PRIV_DN_ATTR:-cn}"
else
  WARDEN_PRIV_DN_ATTR="${WARDEN_PRIV_DN_ATTR:-uid}"
fi
export WARDEN_PRIV_DN_ATTR

# ─── the BIG-IP admin group ──────────────────────────────────────────────────
# The group whose members get Administrator on the target BIG-IP. Everyone else who
# authenticates lands on the default role (guest / read-only).
WARDEN_ADMIN_GROUP_DN="${WARDEN_ADMIN_GROUP_DN:-cn=bigip-admins,ou=groups,${BASE_DN}}"

# How the BIG-IP's remote-role decides "is this user an admin" — an <attribute>=<value>
# string it evaluates against the authenticated user's LDAP attributes.
#   bundled  : the seeded privileged accounts carry employeeType=warden-admins (the
#              historical stamp), so keep that to avoid changing seeded behavior.
#   external : your existing users already carry memberOf — map on the group itself, which
#              is what "define the BIG-IP admin group" should mean in a real directory.
if [ -z "${WARDEN_ADMIN_ROLE_ATTRIBUTE:-}" ]; then
  if warden_is_bundled; then
    WARDEN_ADMIN_ROLE_ATTRIBUTE="employeeType=${WARDEN_ADMIN_GROUP_ATTR_VALUE:-warden-admins}"
  else
    WARDEN_ADMIN_ROLE_ATTRIBUTE="memberOf=${WARDEN_ADMIN_GROUP_DN}"
  fi
fi

# ─── TLS material the BIG-IP validates LDAPS against ─────────────────────────
# bundled: the CA gen-certs.sh made. external: export your directory's CA to a PEM and
# point WARDEN_LDAP_CA_FILE at it (AD: the issuing CA of the DC's LDAPS cert).
if warden_is_bundled; then
  WARDEN_LDAP_CA_FILE="${WARDEN_LDAP_CA_FILE:-certs/ca.crt}"
  WARDEN_LDAP_CA_NAME="${WARDEN_LDAP_CA_NAME:-warden-ca.crt}"
else
  : "${WARDEN_LDAP_CA_FILE:?external mode: set WARDEN_LDAP_CA_FILE to your directory CA PEM (LDAPS validates against it)}"
  WARDEN_LDAP_CA_NAME="${WARDEN_LDAP_CA_NAME:-warden-dir-ca.crt}"
fi

# ─── OpenBao's view of the directory ─────────────────────────────────────────
# bundled talks over the compose network by service name; external over the wire.
if warden_is_bundled; then
  WARDEN_BAO_LDAP_URL="${WARDEN_BAO_LDAP_URL:-ldap://openldap:389}"
else
  WARDEN_BAO_LDAP_URL="${WARDEN_BAO_LDAP_URL:-ldaps://${WARDEN_LDAP_HOST}:${WARDEN_LDAPS_PORT}}"
fi

# ─── the stamp OpenBao's EPHEMERAL role writes on accounts it creates ────────
# The ephemeral flow creates throwaway accounts, so it must stamp whatever attribute the
# remote-role maps on. That works for attribute-based mapping (employeeType=..., or any
# attribute your schema allows); it CANNOT work for memberOf, which directories compute
# from group membership rather than accept as an attribute. With group-based mapping, use
# WARDEN_CRED_MODE=static against accounts you pre-created and pre-added to the group —
# that is also the APM injection path. See docs/directory.md.
WARDEN_ADMIN_ROLE_ATTR="${WARDEN_ADMIN_ROLE_ATTRIBUTE%%=*}"
WARDEN_ADMIN_ROLE_VALUE="${WARDEN_ADMIN_ROLE_ATTRIBUTE#*=}"
if [ "$(printf '%s' "$WARDEN_ADMIN_ROLE_ATTR" | tr 'A-Z' 'a-z')" = memberof ]; then
  WARDEN_PRIV_STAMP_LDIF=""      # group-based mapping: nothing to stamp (static mode only)
else
  WARDEN_PRIV_STAMP_LDIF="${WARDEN_ADMIN_ROLE_ATTR}: ${WARDEN_ADMIN_ROLE_VALUE}"
fi

export WARDEN_PRIV_STAMP_LDIF WARDEN_ADMIN_ROLE_ATTR WARDEN_ADMIN_ROLE_VALUE
export WARDEN_DIRECTORY_MODE WARDEN_LDAP_HOST WARDEN_LDAP_PORT WARDEN_LDAPS_PORT \
       WARDEN_LDAP_SCHEMA WARDEN_BIND_DN WARDEN_DIR_ADMIN_DN WARDEN_DIR_ADMIN_PW \
       WARDEN_USER_SEARCH_BASE WARDEN_PRIV_SEARCH_BASE WARDEN_LOGIN_ATTR \
       WARDEN_ADMIN_GROUP_DN WARDEN_ADMIN_ROLE_ATTRIBUTE \
       WARDEN_LDAP_CA_FILE WARDEN_LDAP_CA_NAME WARDEN_BAO_LDAP_URL

warden_directory_summary() {
  echo "directory: ${WARDEN_DIRECTORY_MODE} @ ${WARDEN_LDAP_HOST} — identities ${WARDEN_USER_SEARCH_BASE}, privileged ${WARDEN_PRIV_SEARCH_BASE}"
  echo "admin group: ${WARDEN_ADMIN_GROUP_DN}  (BIG-IP maps: ${WARDEN_ADMIN_ROLE_ATTRIBUTE})"
}
