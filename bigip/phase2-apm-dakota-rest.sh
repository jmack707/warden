#!/usr/bin/env bash
# Phase 2 (decision core) — build the APM cert -> CN -> LDAP memberOf -> GROUP BRANCH
# -> Allow/Deny policy on bigipa.dakota, plus a test VIP. This is the access-DECISION
# half of the PUA front door (no webtop/SSO/OpenBao-injection yet) — enough to test the
# alice/bob/carol matrix with `curl --cert`.
#
# Graph:  Start -> Client Cert Inspection (valid==0)
#            ok  -> Extract CN -> LDAP Query (uid=<CN>, returns memberOf)
#                     found -> Group Check (memberOf ~ cn=bigip-admins)
#                                yes -> Allow      no -> Deny
#            fail-> Deny  (expired/invalid cert)
#
# Modeled on the working bigip-apm-cert-ldap role (REST + one policy transaction).
# Additive/idempotent (tolerates 409). Requires BIGIP_PASS + BIND_PW in env/.env.
# The CA (pua-lab-ca.crt) is already installed from Phase 1.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
_PASS_IN="${BIGIP_PASS:-}"; set -a; . "${HERE}/../.env"; set +a
[ -n "$_PASS_IN" ] && BIGIP_PASS="$_PASS_IN"
: "${BIGIP_PASS:?export BIGIP_PASS}"; : "${BIND_PW:?need BIND_PW}"

B="https://${BIGIP_MGMT}"; A=(-sk -u "${BIGIP_USER}:${BIGIP_PASS}")
P=pua-apm                      # object-name prefix / access-profile name
PART=Common
CA=pua-lab-ca.crt              # installed in Phase 1
AAA=pua-openldap-aaa
LDAP_HOST="${LAB_HOST_IP}"     # 10.2.20.30 (OpenLDAP)
PEOPLE="ou=people,${BASE_DN}"
BINDDN="cn=bigip-bind,ou=svc,${BASE_DN}"
GROUP_DN="cn=bigip-admins,ou=groups,${BASE_DN}"   # "BIG-IP Admin" group
VIP_IP="${APM_TEST_VIP:-10.2.20.50}"

step(){ echo; echo "== $* =="; }
# additive POST tolerating 409 (already exists)
add(){ # add <url> <json>
  local code; code=$(curl "${A[@]}" -o /tmp/apm.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$2" "$1")
  echo "  POST ${1##*/tm/} -> $code"
  case "$code" in 200|201|409) ;; *) echo "    $(cat /tmp/apm.out)"; return 1;; esac
}

step "1. client-ssl profile (require client cert, trust = PUA Lab CA)"
add "$B/mgmt/tm/ltm/profile/client-ssl" "$(jq -n --arg n "${P}-clientssl" --arg ca "/$PART/$CA" \
  '{name:$n,partition:"Common",defaultsFrom:"/Common/clientssl",cert:"/Common/default.crt",key:"/Common/default.key",caFile:$ca,peerCertMode:"require"}')"

step "2. LTM pool + APM AAA LDAP server (bind = bigip-bind, for the memberOf query) via tmsh"
# TMOS 21.x APM AAA LDAP requires a server POOL (bare address is rejected). Create the
# pool then the AAA referencing it. Single-quote wrap so the DN commas/quotes pass.
TMSH_AAA="tmsh create ltm pool ${AAA}-pool { members add { ${LDAP_HOST}:389 } monitor tcp } ; tmsh create apm aaa ldap ${AAA} { pool ${AAA}-pool port 389 admin-dn \"${BINDDN}\" admin-encrypted-password \"${BIND_PW}\" base-dn \"${PEOPLE}\" }"
curl "${A[@]}" -X POST -H 'Content-Type: application/json' "$B/mgmt/tm/util/bash" \
  -d "$(jq -n --arg u "-c '${TMSH_AAA}'" '{command:"run",utilCmdArgs:$u}')" \
  | jq -r '.commandResult // "  created pool + pua-openldap-aaa"'

step "2b. teardown the mutable graph (VIP/profile/policy/items/agents) so this re-runs cleanly"
td(){ curl "${A[@]}" -o /dev/null -w "  DEL ${1##*~} -> %{http_code}\n" -X DELETE "$1"; }
td "$B/mgmt/tm/ltm/virtual/~${PART}~${P}-test-vs"
td "$B/mgmt/tm/apm/profile/access/~${PART}~${P}"
td "$B/mgmt/tm/apm/policy/access-policy/~${PART}~${P}"
for it in ent act_certauth act_varassign act_ldapquery act_groupcheck end_allow end_deny; do
  td "$B/mgmt/tm/apm/policy/policy-item/~${PART}~${P}_${it}"; done
td "$B/mgmt/tm/apm/policy/agent/variable-assign/~${PART}~${P}_act_varassign_ag"
td "$B/mgmt/tm/apm/policy/agent/aaa-ldap/~${PART}~${P}_act_ldapquery_ag"
td "$B/mgmt/tm/apm/policy/agent/ending-allow/~${PART}~${P}_end_allow_ag"
td "$B/mgmt/tm/apm/policy/agent/ending-deny/~${PART}~${P}_end_deny_ag"

step "3. agents: variable-assign (extract CN) + aaa-ldap (query, GROUP folded into filter)"
add "$B/mgmt/tm/apm/policy/agent/variable-assign" "$(jq -n --arg n "${P}_act_varassign_ag" \
  '{name:$n,partition:"Common",variables:[{varname:"session.custom.cn",expression:"set cn {}; regexp {CN=([^,/]+)} [mcget {session.ssl.cert.subject}] -> cn; set cn"}]}')"
# memberOf is an OPERATIONAL attr (not returned by a default query), but it CAN be
# filtered on — so the group check is folded into the filter: match only iff the CN's
# entry is a member of bigip-admins. queryresult==1 => valid user AND in the group.
add "$B/mgmt/tm/apm/policy/agent/aaa-ldap" "$(jq -n --arg n "${P}_act_ldapquery_ag" --arg s "/$PART/$AAA" --arg base "$PEOPLE" --arg f "(&(uid=%{session.custom.cn})(memberOf=${GROUP_DN}))" \
  '{name:$n,partition:"Common",type:"query",server:$s,searchDn:$base,filter:$f}')"

step "4. ending agents + customization groups"
add "$B/mgmt/tm/apm/policy/agent/ending-allow" "$(jq -n --arg n "${P}_end_allow_ag" '{name:$n,partition:"Common"}')"
add "$B/mgmt/tm/apm/policy/customization-group" "$(jq -n --arg n "${P}_end_deny_ag" '{name:$n,partition:"Common",source:"/Common/modern",type:"logout"}')"
add "$B/mgmt/tm/apm/policy/agent/ending-deny" "$(jq -n --arg n "${P}_end_deny_ag" --arg cg "/$PART/${P}_end_deny_ag" '{name:$n,partition:"Common",customizationGroup:$cg}')"
for grp in logout:logout eps:eps errormap:errormap framework_installation:framework-installation general_ui:general-ui; do
  n="${grp%%:*}"; t="${grp##*:}"
  add "$B/mgmt/tm/apm/policy/customization-group" "$(jq -n --arg n "${P}_${n}" --arg t "$t" '{name:$n,partition:"Common",source:"/Common/modern",type:$t}')"
done

step "5. policy graph (one transaction)"
TID=$(curl "${A[@]}" -X POST -H 'Content-Type: application/json' -d '{}' "$B/mgmt/tm/transaction" | jq -r '.transId')
echo "  transId=$TID"
tadd(){ # tadd <url> <json>
  local code; code=$(curl "${A[@]}" -o /tmp/apm.out -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H "X-F5-REST-Coordination-Id: $TID" -d "$2" "$1")
  echo "    item -> $code"; [ "$code" = 200 ] || { echo "      $(cat /tmp/apm.out)"; return 1; }
}
PI="$B/mgmt/tm/apm/policy/policy-item/"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_end_allow"),partition:"Common",caption:"Allow",color:1,itemType:"ending",agents:[{name:($p+"_end_allow_ag"),partition:"Common",type:"ending-allow"}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_end_deny"),partition:"Common",caption:"Deny",color:2,itemType:"ending",agents:[{name:($p+"_end_deny_ag"),partition:"Common",type:"ending-deny"}]}')"
# LDAP Query IS the gate now: Successful (queryresult==1) => valid user in bigip-admins
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_ldapquery"),partition:"Common",caption:"LDAP Query (uid + group)",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_ldapquery_ag"),partition:"Common",type:"aaa-ldap"}],
  rules:[{caption:"Successful",expression:"expr {[mcget {session.ldap.last.queryresult}] == 1}",nextItem:("/Common/"+$p+"_end_allow")},
         {caption:"fallback",nextItem:("/Common/"+$p+"_end_deny")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_varassign"),partition:"Common",caption:"Extract CN",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_varassign_ag"),partition:"Common",type:"variable-assign"}],
  rules:[{caption:"fallback",nextItem:("/Common/"+$p+"_act_ldapquery")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_certauth"),partition:"Common",caption:"Client Cert Auth",color:1,itemType:"action",loop:"false",
  rules:[{caption:"Successful",expression:"expr {[mcget {session.ssl.cert.valid}] == \"0\"}",nextItem:("/Common/"+$p+"_act_varassign")},
         {caption:"fallback",nextItem:("/Common/"+$p+"_end_deny")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_ent"),partition:"Common",caption:"Start",color:1,itemType:"entry",loop:"false",
  rules:[{caption:"fallback",nextItem:("/Common/"+$p+"_act_certauth")}]}')"
tadd "$B/mgmt/tm/apm/policy/access-policy/" "$(jq -n --arg p "$P" '{name:$p,partition:"Common",type:"access-policy",startItem:($p+"_ent"),defaultEnding:($p+"_end_allow"),maxMacroLoopCount:1,oneshotMacro:"false",
  items:[{name:($p+"_ent"),partition:"Common"},{name:($p+"_act_certauth"),partition:"Common"},{name:($p+"_act_varassign"),partition:"Common"},{name:($p+"_act_ldapquery"),partition:"Common"},{name:($p+"_end_allow"),partition:"Common"},{name:($p+"_end_deny"),partition:"Common"}]}')"
tadd "$B/mgmt/tm/apm/profile/access/" "$(jq -n --arg p "$P" '{name:$p,partition:"Common",acceptLanguages:["en"],defaultLanguage:"en",accessPolicy:("/Common/"+$p),customizationGroup:("/Common/"+$p+"_logout"),epsGroup:("/Common/"+$p+"_eps"),errormapGroup:("/Common/"+$p+"_errormap"),frameworkInstallationGroup:("/Common/"+$p+"_framework_installation"),generalUiGroup:("/Common/"+$p+"_general_ui"),type:"all",scope:"profile",accessPolicyTimeout:300,inactivityTimeout:900,maxSessionTimeout:604800,logoutUriTimeout:5,maxConcurrentSessions:0,maxInProgressSessions:128,maxFailureDelay:5,minFailureDelay:2,secureCookie:"true",persistentCookie:"false",restrictToSingleClientIp:"false",userIdentityMethod:"http",logSettings:["/Common/default-log-setting"]}')"
echo "  committing transaction..."
curl "${A[@]}" -o /tmp/apm.out -w '  commit -> %{http_code}\n' -X PATCH -H 'Content-Type: application/json' -d '{"state":"VALIDATING"}' "$B/mgmt/tm/transaction/$TID"
grep -q '"state":"COMPLETED"' /tmp/apm.out || { echo "  $(cat /tmp/apm.out)"; }

step "6. test virtual server ${VIP_IP}:443 (client-ssl + access profile)"
add "$B/mgmt/tm/ltm/virtual" "$(jq -n --arg n "${P}-test-vs" --arg d "/$PART/${VIP_IP}:443" --arg cs "/$PART/${P}-clientssl" --arg ap "/$PART/$P" \
  '{name:$n,partition:"Common",destination:$d,mask:"255.255.255.255",ipProtocol:"tcp",
    profiles:[{name:"/Common/tcp"},{name:"/Common/http"},{name:$cs,context:"clientside"},{name:$ap}],
    sourceAddressTranslation:{type:"automap"}}')"

echo; echo "Done. Test:  curl -k --cert certs/clients/<uid>.crt --key certs/clients/<uid>.key https://${VIP_IP}/  ; then read /var/log/apm"
