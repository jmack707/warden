# objects.sh — the BIG-IP objects Warden creates, in DELETE-SAFE order (dependents first).
# Shared by apm-build.sh (which tears the mutable graph down before rebuilding) and
# teardown.sh, so the two can never drift — a new object added to the build shows up in
# teardown automatically.
#
# Each function prints REST paths relative to /mgmt/tm/. Callers prefix the host.

# The per-session graph + delivery objects. Rebuilt on every apm-build run.
warden_apm_objects() {  # warden_apm_objects <prefix> <partition>
  local P="$1" PART="$2" it
  printf '%s\n' \
    "ltm/virtual/~${PART}~${P}-test-vs" \
    "ltm/virtual/~${PART}~${P}-shadow-a-vs" \
    "ltm/virtual/~${PART}~${P}-shadow-b-vs" \
    "apm/profile/access/~${PART}~${P}" \
    "apm/policy/access-policy/~${PART}~${P}"
  for it in ent act_certauth act_varassign act_ldapquery act_groupcheck act_baofetch \
            act_ssocreds act_ssomap act_resourceassign end_allow end_deny; do
    printf '%s\n' "apm/policy/policy-item/~${PART}~${P}_${it}"
  done
  printf '%s\n' \
    "apm/policy/agent/variable-assign/~${PART}~${P}_act_varassign_ag" \
    "apm/policy/agent/aaa-ldap/~${PART}~${P}_act_ldapquery_ag" \
    "apm/policy/agent/irule-event/~${PART}~${P}_act_baofetch_ag" \
    "apm/policy/agent/variable-assign/~${PART}~${P}_act_ssocreds_ag" \
    "apm/policy/agent/variable-assign/~${PART}~${P}_act_ssomap_ag" \
    "apm/policy/agent/resource-assign/~${PART}~${P}_act_resourceassign_ag" \
    "apm/policy/agent/ending-allow/~${PART}~${P}_end_allow_ag" \
    "apm/policy/agent/ending-deny/~${PART}~${P}_end_deny_ag" \
    "apm/resource/portal-access/~${PART}~${P}-bigipa-tmui" \
    "apm/resource/portal-access/~${PART}~${P}-bigipb-tmui" \
    "apm/resource/webtop/~${PART}~${P}-webtop" \
    "apm/sso/form-based/~${PART}~${P}-tmui-sso" \
    "apm/profile/connectivity/~${PART}~${P}-connectivity" \
    "ltm/rule/~${PART}~${P}-openbao-fetch" \
    "ltm/rule/~${PART}~${P}-referer-strip" \
    "ltm/rule/~${PART}~${P}-shadow-a-node" \
    "ltm/rule/~${PART}~${P}-shadow-b-node" \
    "ltm/data-group/internal/~${PART}~warden_openbao_dg"
}

# Objects the build creates but does NOT recreate per run (teardown-only). The client-ssl
# profile and AAA are referenced by the graph above, so they must go after it.
warden_apm_support_objects() {  # warden_apm_support_objects <prefix> <partition> <aaa-name>
  local P="$1" PART="$2" AAA="$3"
  printf '%s\n' \
    "ltm/profile/client-ssl/~${PART}~${P}-clientssl" \
    "apm/aaa/ldap/~${PART}~${AAA}" \
    "ltm/pool/~${PART}~${AAA}-pool"
}

# Phase-1 system-auth objects. NOTE: the caller must flip `auth source` back to local
# BEFORE deleting these — see teardown.sh.
warden_auth_objects() {  # warden_auth_objects <ca-cert-name>
  printf '%s\n' \
    "auth/remote-role/role-info/warden_admins" \
    "auth/ldap/system-auth" \
    "sys/file/ssl-cert/~Common~${1}"
}
