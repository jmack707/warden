#!/usr/bin/env bash
# Shared credential abstraction over OpenBao. SOURCE this (do not execute).
# One interface, two models selected by PUA_CRED_MODE — see ADR 0006.
#
#   cred_issue [principal]   -> JSON {mode, username, password, handle, ttl} on stdout
#   cred_revoke <handle>     -> revoke/rotate; handle came from cred_issue
#
# Requires: the repo .env already sourced (BAO_TOKEN) and `jq`.
#
#   ephemeral : a throwaway leased account is minted (username is random pua-…). The
#               `principal` arg is ignored. handle = the OpenBao lease id.
#   static    : a standing account's password is rotated (username = the principal/CN).
#               `principal` is REQUIRED and its static role must already exist
#               (scripts/configure-openbao-static.sh <CN>). handle = the principal.

PUA_CRED_MODE="${PUA_CRED_MODE:-ephemeral}"
PUA_EPHEMERAL_ROLE="${PUA_EPHEMERAL_ROLE:-pua-admin}"   # ldap/creds/<role> used in ephemeral mode

_cred_bao() { docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao bao "$@"; }

cred_issue() {
  local principal="${1:-}"
  case "$PUA_CRED_MODE" in
    ephemeral)
      _cred_bao read -format=json "ldap/creds/${PUA_EPHEMERAL_ROLE}" \
        | jq '{mode:"ephemeral", username:.data.username, password:.data.password, handle:.lease_id, ttl:.lease_duration}'
      ;;
    static)
      [ -n "$principal" ] || { echo "PUA_CRED_MODE=static requires a principal (CN)" >&2; return 2; }
      _cred_bao write -f "ldap/rotate-role/${principal}" >/dev/null
      _cred_bao read -format=json "ldap/static-cred/${principal}" \
        | jq --arg u "$principal" '{mode:"static", username:$u, password:.data.password, handle:$u, ttl:.data.ttl}'
      ;;
    *)
      echo "unknown PUA_CRED_MODE: '${PUA_CRED_MODE}' (want: ephemeral | static)" >&2; return 2
      ;;
  esac
}

# handle shape is self-describing: a lease id contains '/', a static principal does not.
cred_revoke() {
  local handle="${1:?cred_revoke <handle>}"
  if [[ "$handle" == */* ]]; then
    _cred_bao lease revoke "$handle" && echo "==> ephemeral lease revoked (account deleted): $handle"
  else
    _cred_bao write -f "ldap/rotate-role/${handle}" >/dev/null \
      && echo "==> static credential rotated (old password invalidated): $handle"
  fi
}
