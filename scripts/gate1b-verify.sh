#!/usr/bin/env bash
# GATE 1B (automatable subset) — run AFTER the operator flips bigipa auth source to
# ldap. Proves an ephemeral credential authenticates to bigipa for both the GUI/TMUI
# path (iControl REST honours the same remote LDAP auth) and SSH, that a non-pua-admins
# user is denied, that revoke ends auth, and that local admin still works (recovery).
#
# Requires: BIGIP_PASS in env (local-admin cred, from lab OpenBao) for the recovery check.
# Needs sshpass (auto-checked). Prints no ephemeral passwords.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
B="https://${BIGIP_MGMT}"
pass=0; fail=0
ok(){ echo "  PASS: $*"; pass=$((pass+1)); }
no(){ echo "  FAIL: $*"; fail=$((fail+1)); }
bao(){ docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao bao "$@"; }

command -v sshpass >/dev/null || { echo "installing sshpass..."; apt-get install -y -qq sshpass >/dev/null 2>&1; }

echo "== issue an ephemeral pua-admins credential =="
CRED="$(bao read -format=json ldap/creds/pua-admin)"
U="$(jq -r .data.username <<<"$CRED")"; PW="$(jq -r .data.password <<<"$CRED")"; LEASE="$(jq -r .lease_id <<<"$CRED")"
echo "  uid=$U"

echo "== 1. TMUI-equivalent auth (iControl REST GUI login) as ephemeral user =="
code=$(curl -sk -o /dev/null -w '%{http_code}' -u "$U:$PW" "$B/mgmt/tm/sys/version")
[ "$code" = 200 ] && ok "REST/TMUI login 200 (administrator)" || no "REST/TMUI login got $code"

echo "== 2. SSH auth (tmsh) as ephemeral user =="
out=$(sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
        "$U@${BIGIP_MGMT}" 'show sys version' 2>&1 | head -3)
grep -qiE "Sys::Version|BIG-IP|21\.1" <<<"$out" && ok "SSH tmsh landing works" || no "SSH failed: $out"

echo "== 3. negative: user WITHOUT employeeType=pua-admins is denied =="
NEG="neg-$(date +%s 2>/dev/null || echo x)$RANDOM"
cat > /tmp/neg.ldif <<EOF
dn: uid=${NEG},ou=users,${BASE_DN}
objectClass: inetOrgPerson
uid: ${NEG}
cn: ${NEG}
sn: nomember
userPassword: NegTest1!
EOF
ldapadd -x -H "ldap://${LAB_HOST_IP}" -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PW}" -f /tmp/neg.ldif >/dev/null 2>&1
ncode=$(curl -sk -o /dev/null -w '%{http_code}' -u "$NEG:NegTest1!" "$B/mgmt/tm/sys/version")
[ "$ncode" = 401 ] && ok "non-pua-admins denied (401)" || no "non-member got $ncode (expected 401)"
ldapdelete -x -H "ldap://${LAB_HOST_IP}" -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PW}" "uid=${NEG},ou=users,${BASE_DN}" >/dev/null 2>&1
rm -f /tmp/neg.ldif

echo "== 4. revoke ends auth =="
bao lease revoke "$LEASE" >/dev/null 2>&1
sleep 1
rcode=$(curl -sk -o /dev/null -w '%{http_code}' -u "$U:$PW" "$B/mgmt/tm/sys/version")
[ "$rcode" = 401 ] && ok "revoked credential rejected (401)" || no "revoked cred still $rcode"

echo "== 5. recovery: local admin still works =="
if [ -n "${BIGIP_PASS:-}" ]; then
  acode=$(curl -sk -o /dev/null -w '%{http_code}' -u "admin:${BIGIP_PASS}" "$B/mgmt/tm/sys/version")
  [ "$acode" = 200 ] && ok "local admin still authenticates (200)" || no "local admin got $acode"
else
  echo "  SKIP: set BIGIP_PASS to check local-admin recovery"
fi

echo
echo "GATE 1B (automatable subset): ${pass} passed, ${fail} failed."
echo "Remaining [HUMAN]: Guacamole SSH connection in the web UI (T1.8), lease-expiry"
echo "auto-delete at default_ttl, and /var/log/secure event review on bigipa."
[ "$fail" -eq 0 ]
