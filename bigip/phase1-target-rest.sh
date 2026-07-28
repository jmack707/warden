#!/usr/bin/env bash
# T1.7 — Phase 1 target BIG-IP auth config via iControl REST. Mirrors
# bigip/phase1-target.tmsh 1:1. Idempotent-ish (uses PUT/PATCH where possible).
#
# Requires env: BIGIP_MGMT, BIGIP_USER, BIGIP_PASS, BIND_PW, plus LAB_HOST_IP/BASE_DN
# from .env. BIGIP_PASS is NOT stored in the repo — export it at run time (in the
# Dakota lab it is sourced from the lab OpenBao at kv/bigip/common).
#
# SAFETY: admin/root stay local on TMOS; flipping auth source to ldap cannot lock
# them out. Keep a console open anyway (ssh root@192.168.99.6 'qm terminal 210').
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
: "${BIGIP_PASS:?export BIGIP_PASS (or source it from OpenBao) before running}"

B="https://${BIGIP_MGMT}"
AUTH=(-sk -u "${BIGIP_USER}:${BIGIP_PASS}")
CA="${HERE}/../certs/ca.crt"

jqok() { jq -e "$1" >/dev/null 2>&1; }
step() { echo; echo "== $* =="; }

# helper: POST/PATCH JSON, print + fail on HTTP >=400
req() { # req METHOD URL JSON
  local m="$1" url="$2" body="${3:-}"
  local out code
  if [ -n "$body" ]; then
    out="$(curl "${AUTH[@]}" -w '\n%{http_code}' -X "$m" -H 'Content-Type: application/json' -d "$body" "$url")"
  else
    out="$(curl "${AUTH[@]}" -w '\n%{http_code}' -X "$m" "$url")"
  fi
  code="$(tail -n1 <<<"$out")"; body="$(sed '$d' <<<"$out")"
  echo "  HTTP $code  ${url#$B}"
  [ "$code" -lt 400 ] || { echo "$body" | jq . 2>/dev/null || echo "$body"; echo "REST call failed" >&2; exit 1; }
  echo "$body"
}

step "0a. pre-flight: bigipa -> ${LAB_HOST_IP}:636 reachability (mgmt plane)"
PF="$(req POST "$B/mgmt/tm/util/bash" \
  "{\"command\":\"run\",\"utilCmdArgs\":\"-c 'echo | openssl s_client -connect ${LAB_HOST_IP}:636 -CAfile /var/tmp/ca.crt 2>&1 | grep -E \\\"Verify return code|subject=\\\" | head -3'\"}")"
echo "$PF" | jq -r '.commandResult // "(no output)"'

step "0b. upload CA cert to /var/config/rest/downloads/ca.crt"
# small file: single chunk upload
SZ=$(stat -c%s "$CA")
curl "${AUTH[@]}" -X POST \
  -H "Content-Type: application/octet-stream" \
  -H "Content-Range: 0-$((SZ-1))/${SZ}" \
  --data-binary @"$CA" \
  "$B/mgmt/shared/file-transfer/uploads/ca.crt" -o /dev/null -w '  upload HTTP %{http_code}\n'

step "0c. install cert object warden-ca.crt"
# create-or-update the sys file ssl-cert
if curl "${AUTH[@]}" "$B/mgmt/tm/sys/file/ssl-cert/warden-ca.crt" | jqok '.name'; then
  echo "  cert object already exists — skipping create"
else
  req POST "$B/mgmt/tm/sys/file/ssl-cert" \
    '{"name":"warden-ca.crt","sourcePath":"file:/var/config/rest/downloads/ca.crt"}' >/dev/null
fi

step "1. create/replace auth ldap system-auth"
LDAP_BODY="$(jq -n \
  --arg srv "${LAB_HOST_IP}" \
  --arg bdn "cn=bigip-bind,ou=svc,${BASE_DN}" \
  --arg bpw "${BIND_PW}" \
  --arg sbd "ou=users,${BASE_DN}" \
  '{name:"system-auth",servers:[$srv],port:636,ssl:"enabled",
    sslCaCertFile:"warden-ca.crt",bindDn:$bdn,bindPw:$bpw,
    searchBaseDn:$sbd,loginAttribute:"uid"}')"
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

step "3. remote-role role-info warden_admins (employeeType=warden-admins -> administrator)"
RR_BODY='{"name":"warden_admins","attribute":"employeeType=warden-admins","role":"administrator","userPartition":"All","console":"tmsh","lineOrder":1}'
if curl "${AUTH[@]}" "$B/mgmt/tm/auth/remote-role/role-info/warden_admins" | jqok '.name'; then
  req PATCH "$B/mgmt/tm/auth/remote-role/role-info/warden_admins" "$RR_BODY" >/dev/null
else
  req POST  "$B/mgmt/tm/auth/remote-role/role-info" "$RR_BODY" >/dev/null
fi

step "4. switch auth source to ldap  (admin/root stay local)"
req PATCH "$B/mgmt/tm/auth/source" '{"type":"ldap"}' >/dev/null

step "5. save sys config"
req POST "$B/mgmt/tm/sys/config" '{"command":"save"}' >/dev/null

echo; echo "T1.7 complete: bigipa now authenticates remote users against ${LAB_HOST_IP} over LDAPS."
