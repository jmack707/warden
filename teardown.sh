#!/usr/bin/env bash
# Warden teardown — remove what deploy.sh created, in reverse dependency order.
#
#   ./teardown.sh --bigip [--yes]        # BIG-IP config only (leave the local stack up)
#   ./teardown.sh --stack [--yes]        # local stack only (leave the BIG-IP configured)
#   ./teardown.sh --all   [--yes]        # both (default if neither is given)
#   ./teardown.sh --all --purge --yes    # also drop volumes + generated certs/keys
#   ./teardown.sh --all --dry-run        # print exactly what WOULD be removed
#
# What it never touches:
#   * the BIG-IP's local admin/root accounts, or its licence/provisioning
#   * YOUR directory in external mode — no entry is ever deleted there (Warden created
#     none). Only the OpenBao static roles that referenced it are removed.
#   * BIG-IP objects Warden did not create
#
# Order matters on the BIG-IP: auth source flips back to LOCAL *first*, so remote auth is
# never pointed at a half-deleted config. admin/root are local, so this cannot lock you out.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
[ -f .env ] || { echo "no .env — nothing to tear down (run from the repo root)" >&2; exit 1; }
_PASS_IN="${BIGIP_PASS:-}"; set -a; . ./.env; set +a
[ -n "$_PASS_IN" ] && BIGIP_PASS="$_PASS_IN"
# shellcheck disable=SC1091
. ./scripts/lib/directory.sh
# shellcheck disable=SC1091
. ./bigip/lib/objects.sh

DO_BIGIP=0; DO_STACK=0; PURGE=0; YES=0; DRY=0
while [ $# -gt 0 ]; do case "$1" in
  --bigip) DO_BIGIP=1;; --stack) DO_STACK=1;; --all) DO_BIGIP=1; DO_STACK=1;;
  --purge) PURGE=1;; --yes|-y) YES=1;; --dry-run|-n) DRY=1;;
  -h|--help) sed -n '2,20p' "$0"; exit 0;;
  *) echo "unknown arg: $1 (see --help)" >&2; exit 2;;
esac; shift; done
[ $((DO_BIGIP+DO_STACK)) -gt 0 ] || { DO_BIGIP=1; DO_STACK=1; }

P=warden-apm; PART=Common; AAA=warden-openldap-aaa
B="https://${BIGIP_MGMT:-}"; A=(-sk -u "${BIGIP_USER:-admin}:${BIGIP_PASS:-}")

echo "== Warden teardown =="
echo "   BIG-IP config : $([ $DO_BIGIP = 1 ] && echo "yes (${BIGIP_MGMT:-unset})" || echo no)"
echo "   local stack   : $([ $DO_STACK = 1 ] && echo yes || echo no)"
echo "   purge data    : $([ $PURGE = 1 ] && echo "YES — volumes + generated keys" || echo "no (containers stop, data kept)")"
echo "   directory     : ${WARDEN_DIRECTORY_MODE}$(warden_is_bundled && echo " (its data lives in the ldapdata volume)" || echo " — EXTERNAL, never modified")"
[ $DRY = 1 ] && echo "   MODE          : dry run, nothing will be changed"

if [ $DRY = 0 ] && [ $YES = 0 ]; then
  printf '\nThis removes the Warden configuration listed above. Type "yes" to continue: '
  read -r ans; [ "$ans" = yes ] || { echo "aborted"; exit 1; }
fi

del() { # del <rest-subpath>
  if [ $DRY = 1 ]; then echo "  WOULD DELETE ${1}"; return 0; fi
  curl "${A[@]}" -o /dev/null -w "  DEL ${1##*~} -> %{http_code}\n" -X DELETE "$B/mgmt/tm/${1}"
}
patch() { # patch <rest-subpath> <json> <label>
  if [ $DRY = 1 ]; then echo "  WOULD PATCH ${1} ${2}"; return 0; fi
  curl "${A[@]}" -o /dev/null -w "  ${3} -> %{http_code}\n" -X PATCH \
    -H 'Content-Type: application/json' -d "$2" "$B/mgmt/tm/${1}"
}
tmsh() { # tmsh <command>
  if [ $DRY = 1 ]; then echo "  WOULD tmsh ${1}"; return 0; fi
  curl "${A[@]}" -s -X POST -H 'Content-Type: application/json' "$B/mgmt/tm/util/bash" \
    -d "$(jq -n --arg u "-c '$1'" '{command:"run",utilCmdArgs:$u}')" \
    | jq -r '.commandResult // "  ok"' 2>/dev/null || true
}

# ─── OpenBao: stop rotating, drop the roles (do this while the stack is still up) ─────
if [ $DO_STACK = 1 ] || [ $DO_BIGIP = 1 ]; then
  echo; echo "== OpenBao: revoke leases + remove roles =="
  if [ $DRY = 1 ]; then
    echo "  WOULD revoke ldap/creds/warden-admin leases and delete static roles"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx openbao; then
    bao(){ docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN:-root}" openbao bao "$@" 2>/dev/null; }
    bao lease revoke -prefix ldap/creds/warden-admin >/dev/null && echo "  ephemeral leases revoked" \
      || echo "  (no ephemeral leases)"
    # static roles: stop OpenBao rotating accounts that are about to be orphaned. In
    # external mode this leaves YOUR account in place — with whatever password OpenBao
    # last set. Reset it yourself afterwards (printed as a reminder below).
    for r in $(bao list -format=json ldap/static-role 2>/dev/null | jq -r '.[]?' ); do
      bao delete "ldap/static-role/${r}" >/dev/null && echo "  static role removed: ${r}"
    done
    bao secrets disable ldap >/dev/null && echo "  ldap secrets engine disabled" || true
  else
    echo "  openbao container not running — skipping (roles die with the dev-mode container)"
  fi
fi

# ─── BIG-IP ───────────────────────────────────────────────────────────────────────────
if [ $DO_BIGIP = 1 ]; then
  : "${BIGIP_MGMT:?BIGIP_MGMT not set in .env}"
  : "${BIGIP_PASS:?export BIGIP_PASS (or set it in .env) to reach the BIG-IP}"

  echo; echo "== BIG-IP 1. auth source back to LOCAL (before deleting the ldap config) =="
  patch "auth/source" '{"type":"local"}' "auth source -> local"

  echo; echo "== BIG-IP 2. remote-user defaults back to the safe default =="
  # Warden set defaultRole=guest so any authenticated remote user got read-only. Restore
  # no-access, so a future auth source cannot silently grant access.
  patch "auth/remote-user" '{"defaultRole":"no-access","remoteConsoleAccess":"disabled"}' "remote-user -> no-access"

  echo; echo "== BIG-IP 3. APM policy graph + delivery objects =="
  while IFS= read -r o; do del "$o"; done < <(warden_apm_objects "$P" "$PART")

  echo; echo "== BIG-IP 4. supporting objects (client-ssl, AAA, pool) =="
  while IFS= read -r o; do del "$o"; done < <(warden_apm_support_objects "$P" "$PART" "$AAA")

  echo; echo "== BIG-IP 5. system-auth (ldap config, remote-role, trust anchors) =="
  while IFS= read -r o; do del "$o"; done < <(warden_auth_objects "${WARDEN_LDAP_CA_NAME}")
  # the client-cert CA object is separate from the LDAPS one when they differ
  [ "${WARDEN_LDAP_CA_NAME}" = warden-ca.crt ] || del "sys/file/ssl-cert/~Common~warden-ca.crt"

  echo; echo "== BIG-IP 6. save config =="
  if [ $DRY = 1 ]; then echo "  WOULD save sys config"; else
    curl "${A[@]}" -o /dev/null -w "  save -> %{http_code}\n" -X POST \
      -H 'Content-Type: application/json' -d '{"command":"save"}' "$B/mgmt/tm/sys/config"
  fi
  echo "  NOTE: admin/root and the local auth source are untouched — log in with them."
fi

# ─── local stack ──────────────────────────────────────────────────────────────────────
if [ $DO_STACK = 1 ]; then
  echo; echo "== local stack =="
  COMPOSE=(docker compose)
  warden_is_bundled && COMPOSE=(docker compose --profile bundled)
  if [ $DRY = 1 ]; then
    echo "  WOULD ${COMPOSE[*]} down$([ $PURGE = 1 ] && echo ' -v')"
  else
    "${COMPOSE[@]}" down $([ $PURGE = 1 ] && echo -v) 2>&1 | sed 's/^/  /'
  fi
  if [ $PURGE = 1 ]; then
    echo "== purge generated material (CA, server + client certs, rendered LDIFs) =="
    if [ $DRY = 1 ]; then
      echo "  WOULD rm certs/{ca,ldap}.{crt,key,csr} certs/*.srl certs/san.cnf clients/* openbao/{creation,deletion,rollback}.ldif"
    else
      # certs/ may be container-owned (osixia chowns it) — reclaim first
      # shellcheck disable=SC1091
      . ./scripts/lib/certs.sh; ensure_certs_writable ./certs || true
      rm -f certs/ca.crt certs/ca.key certs/ca.srl certs/ldap.crt certs/ldap.key certs/ldap.csr \
            certs/san.cnf certs/dhparam.pem clients/* \
            openbao/creation.ldif openbao/deletion.ldif openbao/rollback.ldif
      echo "  removed. NOTE: a re-deploy mints a NEW CA, so re-import the browser certs."
    fi
  fi
fi

echo
echo "== teardown complete =="
if ! warden_is_bundled; then
  cat <<EOF
Your directory (${WARDEN_LDAP_HOST}) was NOT modified — Warden never created entries there.
Two things it DID change that you may want to undo yourself:
  * passwords of the privileged accounts under ${WARDEN_PRIV_SEARCH_BASE} (OpenBao rotated
    them; they are now set to values nobody holds) — reset them in your directory
  * nothing else: group membership, identities and ACLs are as you had them
EOF
fi
[ $PURGE = 0 ] && [ $DO_STACK = 1 ] && echo "Data volumes kept — re-run ./deploy.sh to bring it all back, or add --purge to wipe."
exit 0
