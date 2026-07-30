#!/usr/bin/env bash
# T1.7 — Phase 1 target BIG-IP auth config via iControl REST. Mirrors
# bigip/phase1-target.tmsh 1:1. Idempotent-ish (uses PUT/PATCH where possible).
#
# Requires env: BIGIP_MGMT, BIGIP_USER, BIGIP_PASS, BIND_PW, plus WARDEN_HOST_IP/BASE_DN
# from .env. BIGIP_PASS is NOT stored in the repo — export it at run time (in the
# Dakota lab it is sourced from the lab OpenBao at kv/bigip/common).
#
# SAFETY: admin/root stay local on TMOS; flipping auth source to ldap cannot lock
# them out. Keep a console open anyway (ssh root@192.168.99.6 'qm terminal 210').
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
# shellcheck disable=SC1091
. "${HERE}/../scripts/lib/directory.sh"
: "${BIGIP_PASS:?export BIGIP_PASS (or source it from OpenBao) before running}"

B="https://${BIGIP_MGMT}"
AUTH=(-sk -u "${BIGIP_USER}:${BIGIP_PASS}")
# CA the BIG-IP validates LDAPS against: the bundled OpenLDAP's CA, or your directory's
# (WARDEN_LDAP_CA_FILE). Relative paths resolve from the repo root.
case "${WARDEN_LDAP_CA_FILE}" in /*) CA="${WARDEN_LDAP_CA_FILE}";; *) CA="${HERE}/../${WARDEN_LDAP_CA_FILE}";; esac
[ -f "$CA" ] || { echo "directory CA not found: $CA (set WARDEN_LDAP_CA_FILE)" >&2; exit 1; }
CA_NAME="${WARDEN_LDAP_CA_NAME}"
echo "== $(warden_directory_summary) =="

jqok() { jq -e "$1" >/dev/null 2>&1; }
step() { echo; echo "== $* =="; }

# helper: POST/PATCH JSON, print + fail on HTTP >=400
req() { # req METHOD URL JSON
  local m="$1" url="$2" body="${3:-}"
  local out code
  if [ -n "$body" ]; then
    out="$(curl "${AUTH[@]}" -w '\n%{http_code}' -X "$m" -H 'Content-Type: application/json' -d "$body" "$url")" \
      || { echo "no HTTP response from ${url#$B} — is ${BIGIP_MGMT}:443 reachable from this host?" >&2; exit 1; }
  else
    out="$(curl "${AUTH[@]}" -w '\n%{http_code}' -X "$m" "$url")" \
      || { echo "no HTTP response from ${url#$B} — is ${BIGIP_MGMT}:443 reachable from this host?" >&2; exit 1; }
  fi
  code="$(tail -n1 <<<"$out")"; body="$(sed '$d' <<<"$out")"
  # status + errors go to stderr so they stay visible when a caller captures stdout
  echo "  HTTP $code  ${url#$B}" >&2
  [ "$code" -lt 400 ] || { { echo "$body" | jq . 2>/dev/null || echo "$body"; echo "REST call failed (HTTP $code, user ${BIGIP_USER})"; } >&2; exit 1; }
  echo "$body"
}

step "0a. pre-flight: bigipa -> ${WARDEN_LDAP_HOST}:${WARDEN_LDAPS_PORT} reachability (mgmt plane)"
PF="$(req POST "$B/mgmt/tm/util/bash" \
  "{\"command\":\"run\",\"utilCmdArgs\":\"-c 'echo | openssl s_client -connect ${WARDEN_LDAP_HOST}:${WARDEN_LDAPS_PORT} -CAfile /var/tmp/ca.crt 2>&1 | grep -E \\\"Verify return code|subject=\\\" | head -3'\"}")"
echo "$PF" | grep -o '{.*}' | jq -r '.commandResult // "(no output)"' 2>/dev/null || echo "  (pre-flight diagnostic only — continuing)"

# TWO distinct trust anchors — the same file in bundled mode, different files when you
# bring your own directory, so install them separately:
#   warden-ca.crt   — the CA that signed the CLIENT certs (Warden's own PKI, always
#                     certs/ca.crt). The APM client-ssl profile trusts this.
#   ${CA_NAME}      — the CA that signed the DIRECTORY's LDAPS cert. auth ldap validates
#                     against this. In bundled mode it IS warden-ca.crt.
install_ca() { # install_ca <object-name> <local-pem>
  local name="$1" file="$2" sz
  step "0b/c. install trust anchor ${name} (from ${file##*/})"
  sz=$(stat -c%s "$file")
  curl "${AUTH[@]}" -X POST \
    -H "Content-Type: application/octet-stream" \
    -H "Content-Range: 0-$((sz-1))/${sz}" \
    --data-binary @"$file" \
    "$B/mgmt/shared/file-transfer/uploads/${name}" -o /dev/null -w '  upload HTTP %{http_code}\n'
  # create-or-UPDATE: on re-deploy an existing object still holds the OLD CA, and stale
  # client-cert trust fails closed.
  if curl "${AUTH[@]}" "$B/mgmt/tm/sys/file/ssl-cert/${name}" | jqok '.name'; then
    req PATCH "$B/mgmt/tm/sys/file/ssl-cert/${name}" \
      "{\"sourcePath\":\"file:/var/config/rest/downloads/${name}\"}" >/dev/null
    echo "  cert object updated to the current CA"
  else
    req POST "$B/mgmt/tm/sys/file/ssl-cert" \
      "{\"name\":\"${name}\",\"sourcePath\":\"file:/var/config/rest/downloads/${name}\"}" >/dev/null
  fi
}
CLIENT_CA="${HERE}/../certs/ca.crt"
[ -f "$CLIENT_CA" ] || { echo "client-cert CA missing: $CLIENT_CA (run scripts/gen-certs.sh)" >&2; exit 1; }
install_ca warden-ca.crt "$CLIENT_CA"
[ "$CA_NAME" = warden-ca.crt ] || install_ca "$CA_NAME" "$CA"

step "1. create/replace auth ldap system-auth"
LDAP_BODY="$(jq -n \
  --arg srv "${WARDEN_LDAP_HOST}" \
  --argjson port "${WARDEN_LDAPS_PORT}" \
  --arg ca "${WARDEN_LDAP_CA_NAME}" \
  --arg bdn "${WARDEN_BIND_DN}" \
  --arg bpw "${BIND_PW}" \
  --arg sbd "${WARDEN_PRIV_SEARCH_BASE}" \
  --arg la "${WARDEN_LOGIN_ATTR}" \
  '{name:"system-auth",servers:[$srv],port:$port,ssl:"enabled",
    sslCaCertFile:$ca,bindDn:$bdn,bindPw:$bpw,
    searchBaseDn:$sbd,loginAttribute:$la}')"
if curl "${AUTH[@]}" "$B/mgmt/tm/auth/ldap/system-auth" | jqok '.name'; then
  req PATCH "$B/mgmt/tm/auth/ldap/system-auth" "$LDAP_BODY" >/dev/null
else
  req POST  "$B/mgmt/tm/auth/ldap" "$LDAP_BODY" >/dev/null
fi

step "2. remote-user: default = guest (read-only), console disabled"
# deviation 13: non-admin cert identities authenticate and land on the webtop, then get
# READ-ONLY (guest) on the target BIG-IP. Only bigip-admins members (employeeType stamp,
# step 3) are elevated to administrator. Console stays off for the default (no shell for
# read-only users). Was no-access — flipped to guest to satisfy "everyone else read-only".
req PATCH "$B/mgmt/tm/auth/remote-user" \
  '{"defaultRole":"guest","remoteConsoleAccess":"disabled"}' >/dev/null

step "3. remote-role role-info warden_admins (${WARDEN_ADMIN_ROLE_ATTRIBUTE} -> administrator)"
# THIS is "define the BIG-IP admin group": whoever matches WARDEN_ADMIN_ROLE_ATTRIBUTE gets
# administrator; everyone else who authenticates falls through to the default role (guest).
# bundled default = employeeType=warden-admins (the seeded stamp); external default =
# memberOf=<WARDEN_ADMIN_GROUP_DN>. Override either via .env.
RR_BODY="$(jq -n --arg a "${WARDEN_ADMIN_ROLE_ATTRIBUTE}" \
  '{name:"warden_admins",attribute:$a,role:"administrator",userPartition:"All",console:"tmsh",lineOrder:1}')"
if curl "${AUTH[@]}" "$B/mgmt/tm/auth/remote-role/role-info/warden_admins" | jqok '.name'; then
  req PATCH "$B/mgmt/tm/auth/remote-role/role-info/warden_admins" "$RR_BODY" >/dev/null
else
  req POST  "$B/mgmt/tm/auth/remote-role/role-info" "$RR_BODY" >/dev/null
fi

step "4. switch auth source to ldap  (admin/root stay local)"
req PATCH "$B/mgmt/tm/auth/source" '{"type":"ldap"}' >/dev/null

step "5. save sys config"
req POST "$B/mgmt/tm/sys/config" '{"command":"save"}' >/dev/null

echo; echo "T1.7 complete: bigipa now authenticates remote users against ${WARDEN_LDAP_HOST} over LDAPS."
