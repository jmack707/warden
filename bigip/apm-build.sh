#!/usr/bin/env bash
# Phase 2 (decision core) — build the APM cert -> CN -> LDAP memberOf -> GROUP BRANCH
# -> Allow/Deny policy on bigipa.dakota, plus a test VIP. This is the access-DECISION
# half of the Warden front door (no webtop/SSO/OpenBao-injection yet) — enough to test the
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
# The CA (warden-ca.crt) is already installed from Phase 1.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
_PASS_IN="${BIGIP_PASS:-}"; set -a; . "${HERE}/../.env"; set +a
[ -n "$_PASS_IN" ] && BIGIP_PASS="$_PASS_IN"
: "${BIGIP_PASS:?export BIGIP_PASS}"; : "${BIND_PW:?need BIND_PW}"
: "${APM_TOKEN:?export APM_TOKEN (scoped OpenBao token from scripts/mint-apm-token.sh)}"
IRULE_FILE="${HERE}/apm-openbao-fetch-dakota.irule"

B="https://${BIGIP_MGMT}"; A=(-sk -u "${BIGIP_USER}:${BIGIP_PASS}")
P=warden-apm                      # object-name prefix / access-profile name
PART=Common
CA=warden-ca.crt              # installed in Phase 1
AAA=warden-openldap-aaa
LDAP_HOST="${WARDEN_HOST_IP}"     # OpenLDAP + OpenBao host (the warden VM)
PEOPLE="ou=people,${BASE_DN}"
BINDDN="cn=bigip-bind,ou=svc,${BASE_DN}"
GROUP_DN="cn=bigip-admins,ou=groups,${BASE_DN}"   # "BIG-IP Admin" group
VIP_IP="${WARDEN_APM_VIP:?set WARDEN_APM_VIP in .env}"
# Shadow façades (RFC5737 TEST-NET-1) — APM portal access refuses "reserved" targets
# (self-IPs, mgmt, device-trust/cluster addrs -> 01490585/errorcode=17, deviation 10),
# and exposing TMUI on a routable external self-IP is a security hole (deviation 12).
# Portal resources target these non-routable façade IPs; plain LTM shadow VSs (TCP/TLS
# passthrough, all VLANs so tmm's own portal-engine connection hits them) steer the last
# hop with an iRule `node` (a pool CAN'T hold a self-IP member). Pattern proven on the
# Nora build (bigip-apm-cert-ldap role, K31750304). Needs
# tmm.tcl.rule.node.allow_loopback_addresses=true (set below).
SHADOW_A="${WARDEN_SHADOW_A:-192.0.2.5}"             # -> node 127.0.0.1 = THIS box's TMUI (active unit)
SHADOW_B="${WARDEN_SHADOW_B:-192.0.2.6}"             # -> peer INTERNAL self-IP
BIGIPB_BACKEND="${WARDEN_BIGIP_B_TMUI:-}"             # real last-hop for the B façade (HA peer only)
# HA peer is optional: set WARDEN_BIGIP_B_MGMT (and _TMUI) to add a second bookmark to the
# peer's TMUI. Empty = single standalone BIG-IP: only the A façade (node 127.0.0.1) is built.
HAS_PEER=0; { [ -n "${WARDEN_BIGIP_B_MGMT:-}" ] && [ -n "$BIGIPB_BACKEND" ]; } && HAS_PEER=1
REFERER_IRULE='when HTTP_REQUEST {
    if { [HTTP::uri] contains "tmui/login.jsp" } {
        HTTP::header remove "Referer"
    }
}'

step(){ echo; echo "== $* =="; }
# additive POST tolerating 409 (already exists)
add(){ # add <url> <json>
  local code; code=$(curl "${A[@]}" -o /tmp/apm.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$2" "$1")
  echo "  POST ${1##*/tm/} -> $code"
  case "$code" in 200|201|409) ;; *) echo "    $(cat /tmp/apm.out)"; return 1;; esac
}

step "1. client-ssl profile (require client cert, trust = Warden Lab CA)"
add "$B/mgmt/tm/ltm/profile/client-ssl" "$(jq -n --arg n "${P}-clientssl" --arg ca "/$PART/$CA" \
  '{name:$n,partition:"Common",defaultsFrom:"/Common/clientssl",cert:"/Common/default.crt",key:"/Common/default.key",caFile:$ca,peerCertMode:"require"}')"

step "2. LTM pool + APM AAA LDAP server (bind = bigip-bind, for the memberOf query) via tmsh"
# TMOS 21.x APM AAA LDAP requires a server POOL (bare address is rejected). Create the
# pool then the AAA referencing it. Single-quote wrap so the DN commas/quotes pass.
TMSH_AAA="tmsh create ltm pool ${AAA}-pool { members add { ${LDAP_HOST}:389 } monitor tcp } ; tmsh create apm aaa ldap ${AAA} { pool ${AAA}-pool port 389 admin-dn \"${BINDDN}\" admin-encrypted-password \"${BIND_PW}\" base-dn \"${PEOPLE}\" }"
curl "${A[@]}" -X POST -H 'Content-Type: application/json' "$B/mgmt/tm/util/bash" \
  -d "$(jq -n --arg u "-c '${TMSH_AAA}'" '{command:"run",utilCmdArgs:$u}')" \
  | jq -r '.commandResult // "  created pool + warden-openldap-aaa"'

step "2b. teardown the mutable graph (VIP/profile/policy/items/agents) so this re-runs cleanly"
td(){ curl "${A[@]}" -o /dev/null -w "  DEL ${1##*~} -> %{http_code}\n" -X DELETE "$1"; }
td "$B/mgmt/tm/ltm/virtual/~${PART}~${P}-test-vs"
td "$B/mgmt/tm/ltm/virtual/~${PART}~${P}-shadow-a-vs"
td "$B/mgmt/tm/ltm/virtual/~${PART}~${P}-shadow-b-vs"
td "$B/mgmt/tm/apm/profile/access/~${PART}~${P}"
td "$B/mgmt/tm/apm/policy/access-policy/~${PART}~${P}"
for it in ent act_certauth act_varassign act_ldapquery act_groupcheck act_baofetch act_ssocreds act_ssomap act_resourceassign end_allow end_deny; do
  td "$B/mgmt/tm/apm/policy/policy-item/~${PART}~${P}_${it}"; done
td "$B/mgmt/tm/apm/policy/agent/variable-assign/~${PART}~${P}_act_varassign_ag"
td "$B/mgmt/tm/apm/policy/agent/aaa-ldap/~${PART}~${P}_act_ldapquery_ag"
td "$B/mgmt/tm/apm/policy/agent/irule-event/~${PART}~${P}_act_baofetch_ag"
td "$B/mgmt/tm/apm/policy/agent/variable-assign/~${PART}~${P}_act_ssocreds_ag"
td "$B/mgmt/tm/apm/policy/agent/variable-assign/~${PART}~${P}_act_ssomap_ag"
td "$B/mgmt/tm/apm/policy/agent/resource-assign/~${PART}~${P}_act_resourceassign_ag"
td "$B/mgmt/tm/apm/policy/agent/ending-allow/~${PART}~${P}_end_allow_ag"
td "$B/mgmt/tm/apm/policy/agent/ending-deny/~${PART}~${P}_end_deny_ag"
td "$B/mgmt/tm/apm/resource/portal-access/~${PART}~${P}-bigipa-tmui"
td "$B/mgmt/tm/apm/resource/portal-access/~${PART}~${P}-bigipb-tmui"
td "$B/mgmt/tm/apm/resource/webtop/~${PART}~${P}-webtop"
td "$B/mgmt/tm/apm/sso/form-based/~${PART}~${P}-tmui-sso"
td "$B/mgmt/tm/apm/profile/connectivity/~${PART}~${P}-connectivity"
td "$B/mgmt/tm/ltm/rule/~${PART}~${P}-openbao-fetch"
td "$B/mgmt/tm/ltm/rule/~${PART}~${P}-referer-strip"
td "$B/mgmt/tm/ltm/rule/~${PART}~${P}-shadow-a-node"
td "$B/mgmt/tm/ltm/rule/~${PART}~${P}-shadow-b-node"
td "$B/mgmt/tm/ltm/data-group/internal/~${PART}~warden_openbao_dg"

step "3. agents: variable-assign (extract CN) + aaa-ldap (query, GROUP folded into filter)"
add "$B/mgmt/tm/apm/policy/agent/variable-assign" "$(jq -n --arg n "${P}_act_varassign_ag" \
  '{name:$n,partition:"Common",variables:[{varname:"session.custom.cn",expression:"set cn {}; regexp {CN=([^,/]+)} [mcget {session.ssl.cert.subject}] -> cn; set cn"}]}')"
# AUTHZ MOVED TO THE BIG-IP (deviation 13): APM no longer gates on group membership —
# the query is now identity-only (does uid=<CN> exist?). queryresult==1 => valid cert
# identity => reach webtop/TMUI. The remote BIG-IP's remote-role then decides the role:
# bigip-admins members (employeeType=warden-admins on their ou=users access acct) -> admin,
# everyone else -> default read-only (guest). GROUP_DN kept above for reference only.
add "$B/mgmt/tm/apm/policy/agent/aaa-ldap" "$(jq -n --arg n "${P}_act_ldapquery_ag" --arg s "/$PART/$AAA" --arg base "$PEOPLE" --arg f "(uid=%{session.custom.cn})" \
  '{name:$n,partition:"Common",type:"query",server:$s,searchDn:$base,filter:$f}')"

step "4. ending agents + customization groups"
add "$B/mgmt/tm/apm/policy/agent/ending-allow" "$(jq -n --arg n "${P}_end_allow_ag" '{name:$n,partition:"Common"}')"
add "$B/mgmt/tm/apm/policy/customization-group" "$(jq -n --arg n "${P}_end_deny_ag" '{name:$n,partition:"Common",source:"/Common/modern",type:"logout"}')"
add "$B/mgmt/tm/apm/policy/agent/ending-deny" "$(jq -n --arg n "${P}_end_deny_ag" --arg cg "/$PART/${P}_end_deny_ag" '{name:$n,partition:"Common",customizationGroup:$cg}')"
for grp in logout:logout eps:eps errormap:errormap framework_installation:framework-installation general_ui:general-ui; do
  n="${grp%%:*}"; t="${grp##*:}"
  add "$B/mgmt/tm/apm/policy/customization-group" "$(jq -n --arg n "${P}_${n}" --arg t "$t" '{name:$n,partition:"Common",source:"/Common/modern",type:$t}')"
done

step "4b. OpenBao fetch (iRule + token datagroup) + fetch/SSO-creds agents (Stage B1)"
# iRule that rotates+reads the CN's OpenBao static-cred and stashes the password.
# Rendered with envsubst restricted to ${WARDEN_HOST_IP} so the iRule's own $vars survive.
add "$B/mgmt/tm/ltm/rule" "$(jq -n --arg n "${P}-openbao-fetch" --arg b "$(envsubst '${WARDEN_HOST_IP}' < "$IRULE_FILE")" '{name:$n,partition:"Common",apiAnonymous:$b}')"
# scoped token datagroup for the iRule
add "$B/mgmt/tm/ltm/data-group/internal" "$(jq -n --arg t "$APM_TOKEN" '{name:"warden_openbao_dg",partition:"Common",type:"string",records:[{name:"token",data:$t}]}')"
# iRule Event agent (id must match the iRule's agent_id check)
add "$B/mgmt/tm/apm/policy/agent/irule-event" "$(jq -n --arg n "${P}_act_baofetch_ag" '{name:$n,partition:"Common",id:"openbao_fetch"}')"
# SSO Credentials agent: username = CN, password = the fetched OpenBao value
add "$B/mgmt/tm/apm/policy/agent/variable-assign" "$(jq -n --arg n "${P}_act_ssocreds_ag" \
  '{name:$n,partition:"Common",variables:[
     {varname:"session.sso.token.last.username",expression:"mcget {session.custom.cn}"},
     {varname:"session.sso.token.last.password",expression:"mcget {session.custom.warden.password}",secure:"true"}]}')"

step "4c. shadow façade VSs (non-reserved portal targets; TLS passthrough; iRule node = last hop)"
# loopback node targets (127.0.0.1 / own self-IP) need these; peer targets don't, but harmless
curl "${A[@]}" -X POST -H 'Content-Type: application/json' "$B/mgmt/tm/util/bash" \
  -d '{"command":"run","utilCmdArgs":"-c \"tmsh modify sys db tmm.tcl.rule.connect.allow_loopback_addresses value true; tmsh modify sys db tmm.tcl.rule.node.allow_loopback_addresses value true; echo db-flags-set\""}' | jq -r '.commandResult // "(ok)"'
add "$B/mgmt/tm/ltm/rule" "$(jq -n --arg n "${P}-shadow-a-node" --arg b 'when CLIENT_ACCEPTED {
    node 127.0.0.1 443
}' '{name:$n,partition:"Common",apiAnonymous:$b}')"
mk_shadow_vs(){ # mk_shadow_vs <name> <facade-ip> <irule>
  add "$B/mgmt/tm/ltm/virtual" "$(jq -n --arg n "$1" --arg d "/$PART/$2:443" --arg ir "/$PART/$3" \
    '{name:$n,partition:"Common",destination:$d,mask:"255.255.255.255",ipProtocol:"tcp",
      profiles:[{name:"/Common/tcp"}],rules:[$ir],sourceAddressTranslation:{type:"automap"}}')"
}
mk_shadow_vs "${P}-shadow-a-vs" "$SHADOW_A" "${P}-shadow-a-node"
if [ "$HAS_PEER" = 1 ]; then
  add "$B/mgmt/tm/ltm/rule" "$(jq -n --arg n "${P}-shadow-b-node" --arg b "when CLIENT_ACCEPTED {
    node ${BIGIPB_BACKEND} 443
}" '{name:$n,partition:"Common",apiAnonymous:$b}')"
  mk_shadow_vs "${P}-shadow-b-vs" "$SHADOW_B" "${P}-shadow-b-node"
fi

step "4d. delivery objects: SSO form + webtop + Portal Access (both units via façades) + cred-map/resource-assign (Stage B2)"
# form-based SSO into the target TMUI login page
add "$B/mgmt/tm/apm/sso/form-based" "$(jq -n --arg n "${P}-tmui-sso" \
  '{name:$n,partition:"Common",startUri:"/tmui/login.jsp*",formAction:"/tmui/logmein.html",formUsername:"username",formPassword:"passwd",formMethod:"post",successMatchType:"url",successMatchValue:"/"}')"
# webtop (full) + its customization group
add "$B/mgmt/tm/apm/policy/customization-group" "$(jq -n --arg n "${P}_webtop_cg" '{name:$n,partition:"Common",source:"/Common/modern",type:"webtop"}')"
add "$B/mgmt/tm/apm/resource/webtop" "$(jq -n --arg n "${P}-webtop" --arg cg "/$PART/${P}_webtop_cg" '{name:$n,partition:"Common",customizationGroup:$cg,webtopType:"full"}')"
# Portal Access resources -> each unit's TMUI via its shadow façade, form SSO on the item.
# destipaddr header = façade (node selection: portal engine connects to it); referer =
# façade origin (TMUI login.jsp CSRF). headers are a header_data_t the REST body can't
# express; tmsh sets them. `items modify` merges.
mk_portal(){ # mk_portal <name> <facade-ip> <acl-order>
  add "$B/mgmt/tm/apm/resource/portal-access" "$(jq -n --arg n "$1" --arg h "$2" --argjson o "$3" --arg sso "/$PART/${P}-tmui-sso" \
    '{name:$n,partition:"Common",aclOrder:$o,publishOnWebtop:"true",applicationUri:("https://"+$h+"/tmui/login.jsp"),
      items:{item1:{host:$h,paths:"/*",scheme:"https",port:443,sso:$sso}}}')"
  curl "${A[@]}" -X POST -H 'Content-Type: application/json' "$B/mgmt/tm/util/bash" \
    -d "$(jq -n --arg u "-c 'tmsh modify apm resource portal-access $1 items modify { item1 { headers { { name destipaddr value $2 } { name referer value https://$2:443 } } } }'" '{command:"run",utilCmdArgs:$u}')" | jq -r '.commandResult // "  portal item headers set"'
}
mk_portal "${P}-bigipa-tmui" "$SHADOW_A" 1
[ "$HAS_PEER" = 1 ] && mk_portal "${P}-bigipb-tmui" "$SHADOW_B" 2
# Referer-strip iRule: TMUI login.jsp rejects a mismatched Referer (CSRF) — remove it
add "$B/mgmt/tm/ltm/rule" "$(jq -n --arg n "${P}-referer-strip" --arg b "$REFERER_IRULE" '{name:$n,partition:"Common",apiAnonymous:$b}')"
# connectivity profile (Portal Access requires one on the VS)
add "$B/mgmt/tm/apm/profile/connectivity" "$(jq -n --arg n "${P}-connectivity" '{name:$n,partition:"Common",defaultsFrom:"/Common/connectivity"}')"
# SSO Credential Mapping agent (engages websso; forwards the sso.token.last.* vars)
add "$B/mgmt/tm/apm/policy/agent/variable-assign" "$(jq -n --arg n "${P}_act_ssomap_ag" \
  '{name:$n,partition:"Common",type:"sso-cred-mapping",variables:[
     {varname:"session.sso.token.last.username",expression:"mcget {session.sso.token.last.username}"},
     {varname:"session.sso.token.last.password",expression:"mcget {session.sso.token.last.password}"}]}')"
# Resource Assign agent (webtop + the A bookmark, plus the peer bookmark when HA)
if [ "$HAS_PEER" = 1 ]; then
  RA_RESOURCES="$(jq -n --arg pa "/$PART/${P}-bigipa-tmui" --arg pb "/$PART/${P}-bigipb-tmui" '[$pa,$pb]')"
else
  RA_RESOURCES="$(jq -n --arg pa "/$PART/${P}-bigipa-tmui" '[$pa]')"
fi
add "$B/mgmt/tm/apm/policy/agent/resource-assign" "$(jq -n --arg n "${P}_act_resourceassign_ag" --arg wt "/$PART/${P}-webtop" --argjson res "$RA_RESOURCES" \
  '{name:$n,partition:"Common",type:"general",rules:[{portalAccessResources:$res,webtop:$wt}]}')"

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
# LDAP Query gate: Successful (queryresult==1) => valid user in bigip-admins -> fetch creds
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_ldapquery"),partition:"Common",caption:"LDAP Query (uid + group)",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_ldapquery_ag"),partition:"Common",type:"aaa-ldap"}],
  rules:[{caption:"Successful",expression:"expr {[mcget {session.ldap.last.queryresult}] == 1}",nextItem:("/Common/"+$p+"_act_baofetch")},
         {caption:"fallback",nextItem:("/Common/"+$p+"_end_deny")}]}')"
# OpenBao fetch (iRule Event) -> SSO Credentials -> Allow
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_baofetch"),partition:"Common",caption:"OpenBao Fetch",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_baofetch_ag"),partition:"Common",type:"irule-event"}],
  rules:[{caption:"fallback",nextItem:("/Common/"+$p+"_act_ssocreds")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_ssocreds"),partition:"Common",caption:"SSO Credentials",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_ssocreds_ag"),partition:"Common",type:"variable-assign"}],
  rules:[{caption:"fallback",nextItem:("/Common/"+$p+"_act_ssomap")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_ssomap"),partition:"Common",caption:"SSO Credential Mapping",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_ssomap_ag"),partition:"Common",type:"variable-assign"}],
  rules:[{caption:"fallback",nextItem:("/Common/"+$p+"_act_resourceassign")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_resourceassign"),partition:"Common",caption:"Resource Assign",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_resourceassign_ag"),partition:"Common",type:"resource-assign"}],
  rules:[{caption:"fallback",nextItem:("/Common/"+$p+"_end_allow")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_varassign"),partition:"Common",caption:"Extract CN",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_varassign_ag"),partition:"Common",type:"variable-assign"}],
  rules:[{caption:"fallback",nextItem:("/Common/"+$p+"_act_ldapquery")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_certauth"),partition:"Common",caption:"Client Cert Auth",color:1,itemType:"action",loop:"false",
  rules:[{caption:"Successful",expression:"expr {[mcget {session.ssl.cert.valid}] == \"0\"}",nextItem:("/Common/"+$p+"_act_varassign")},
         {caption:"fallback",nextItem:("/Common/"+$p+"_end_deny")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_ent"),partition:"Common",caption:"Start",color:1,itemType:"entry",loop:"false",
  rules:[{caption:"fallback",nextItem:("/Common/"+$p+"_act_certauth")}]}')"
tadd "$B/mgmt/tm/apm/policy/access-policy/" "$(jq -n --arg p "$P" '{name:$p,partition:"Common",type:"access-policy",startItem:($p+"_ent"),defaultEnding:($p+"_end_allow"),maxMacroLoopCount:1,oneshotMacro:"false",
  items:[{name:($p+"_ent"),partition:"Common"},{name:($p+"_act_certauth"),partition:"Common"},{name:($p+"_act_varassign"),partition:"Common"},{name:($p+"_act_ldapquery"),partition:"Common"},{name:($p+"_act_baofetch"),partition:"Common"},{name:($p+"_act_ssocreds"),partition:"Common"},{name:($p+"_act_ssomap"),partition:"Common"},{name:($p+"_act_resourceassign"),partition:"Common"},{name:($p+"_end_allow"),partition:"Common"},{name:($p+"_end_deny"),partition:"Common"}]}')"
tadd "$B/mgmt/tm/apm/profile/access/" "$(jq -n --arg p "$P" '{name:$p,partition:"Common",acceptLanguages:["en"],defaultLanguage:"en",accessPolicy:("/Common/"+$p),customizationGroup:("/Common/"+$p+"_logout"),epsGroup:("/Common/"+$p+"_eps"),errormapGroup:("/Common/"+$p+"_errormap"),frameworkInstallationGroup:("/Common/"+$p+"_framework_installation"),generalUiGroup:("/Common/"+$p+"_general_ui"),type:"all",scope:"profile",accessPolicyTimeout:300,inactivityTimeout:900,maxSessionTimeout:604800,logoutUriTimeout:5,maxConcurrentSessions:0,maxInProgressSessions:128,maxFailureDelay:5,minFailureDelay:2,secureCookie:"true",persistentCookie:"false",restrictToSingleClientIp:"false",userIdentityMethod:"http",logSettings:["/Common/default-log-setting"]}')"
echo "  committing transaction..."
curl "${A[@]}" -o /tmp/apm.out -w '  commit -> %{http_code}\n' -X PATCH -H 'Content-Type: application/json' -d '{"state":"VALIDATING"}' "$B/mgmt/tm/transaction/$TID"
grep -q '"state":"COMPLETED"' /tmp/apm.out || { echo "  $(cat /tmp/apm.out)"; }

step "6. test virtual server ${VIP_IP}:443 (client-ssl + access profile)"
add "$B/mgmt/tm/ltm/virtual" "$(jq -n --arg n "${P}-test-vs" --arg d "/$PART/${VIP_IP}:443" --arg cs "/$PART/${P}-clientssl" --arg ap "/$PART/$P" --arg ir "/$PART/${P}-openbao-fetch" --arg rs "/$PART/${P}-referer-strip" --arg cp "/$PART/${P}-connectivity" \
  '{name:$n,partition:"Common",destination:$d,mask:"255.255.255.255",ipProtocol:"tcp",
    profiles:[{name:"/Common/tcp"},{name:"/Common/http"},{name:$cs,context:"clientside"},{name:"/Common/serverssl",context:"serverside"},{name:$ap},{name:$cp},{name:"/Common/rewrite-portal"},{name:"/Common/rba"},{name:"/Common/ppp"},{name:"/Common/websso"}],
    rules:[$ir,$rs],
    sourceAddressTranslation:{type:"automap"}}')"

echo; echo "Done. Test:  curl -k --cert clients/<uid>.crt --key clients/<uid>.key https://${VIP_IP}/  ; then read /var/log/apm"
