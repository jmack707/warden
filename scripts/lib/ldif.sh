# ldif.sh — source this. Applies a templated LDIF and FAILS LOUDLY.
#
# Why it exists: seeding used to be `envsubst < x.ldif | ldapadd ... | grep -v ... || true`,
# which swallowed real failures. A directory that silently ended up empty then surfaced four
# steps later as an opaque OpenBao 500 ("LDAP Result Code 32 No Such Object"). Anything that
# is not "entry already exists" now stops the deploy where the problem actually is.
#
# Expects (exported by .env + lib/directory.sh): WARDEN_LDAP_HOST, WARDEN_DIR_ADMIN_DN,
# WARDEN_DIR_ADMIN_PW.

# ldif_apply <label> <file>
ldif_apply() {
  local label="$1" file="$2" out hard
  [ -f "$file" ] || { echo "ldif_apply: no such file: $file" >&2; return 1; }
  out="$(envsubst < "$file" | ldapadd -x -c -H "ldap://${WARDEN_LDAP_HOST}" \
         -D "${WARDEN_DIR_ADMIN_DN}" -w "${WARDEN_DIR_ADMIN_PW}" 2>&1)" || true

  # benign: "adding new entry ..." progress and per-entry "Already exists" (idempotent re-run)
  hard="$(printf '%s\n' "$out" \
          | grep -E '^ldap_(add|bind|modify|sasl_bind):' \
          | grep -viE 'already exists' || true)"
  if [ -n "$hard" ]; then
    echo "  ${label}: FAILED" >&2
    printf '    %s\n' "$hard" >&2
    printf '%s\n' "$out" | grep -A1 -E '^ldap_' | grep -i 'additional info' | sed 's/^/    /' >&2 || true
    case "$hard" in
      *"unwilling to perform"*|*"no global superior"*)
        echo "    → the entry is outside the directory suffix. Check BASE_DN in .env matches" >&2
        echo "      the directory (bundled: it is derived from WARDEN_DOMAIN)." >&2;;
      *"Invalid credentials"*)
        echo "    → check WARDEN_DIR_ADMIN_DN / the admin password in .env." >&2;;
      *"Can't contact"*)
        echo "    → ${WARDEN_LDAP_HOST}:389 not answering yet (see wait_for_ldap)." >&2;;
    esac
    return 1
  fi
  local added; added="$(printf '%s\n' "$out" | grep -c '^adding new entry' || true)"
  echo "  ${label}: ok (${added} entr$([ "$added" = 1 ] && echo y || echo ies) processed)"
}

# wait_for_ldap [seconds] — block until the directory answers a base-scope search on
# BASE_DN *as the admin bind seeding will use*. A fixed `sleep` races the container's
# first-run bootstrap on a fresh volume.
# NOTE: bind, do not probe anonymously — osixia/openldap denies anonymous reads by
# default and returns "No such object" for the base entry, which reads as "not ready"
# forever even though the server is up and the entry exists.
wait_for_ldap() {
  local max="${1:-60}" i=0
  while [ "$i" -lt "$max" ]; do
    if ldapsearch -x -LLL -H "ldap://${WARDEN_LDAP_HOST}" \
         -D "${WARDEN_DIR_ADMIN_DN}" -w "${WARDEN_DIR_ADMIN_PW}" \
         -b "${BASE_DN}" -s base dn >/dev/null 2>&1; then
      [ "$i" -gt 0 ] && echo "  directory ready after ${i}s"
      return 0
    fi
    i=$((i+1)); sleep 1
  done
  echo "  directory at ${WARDEN_LDAP_HOST} did not answer for ${BASE_DN} within ${max}s" >&2
  echo "  last attempt said: $(ldapsearch -x -LLL -H "ldap://${WARDEN_LDAP_HOST}" \
        -D "${WARDEN_DIR_ADMIN_DN}" -w "${WARDEN_DIR_ADMIN_PW}" -b "${BASE_DN}" -s base dn 2>&1 \
        | head -2 | tr '\n' ' ')" >&2
  return 1
}
