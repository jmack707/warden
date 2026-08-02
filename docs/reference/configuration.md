# Configuration reference

Every setting that governs the stack: `.env` variables, the sys `db`/httpd knobs the build
sets on the BIG-IP, and the key BIG-IP object names. Site-specific values use the angle-bracket form, e.g. `<bigip-mgmt-ip>`.

_Last validated: 2026-07._

## Overview
`.env` is the only file you edit. Everything else — DNs, ports, trust anchors, the BIG-IP
object names — is derived from it by `scripts/lib/directory.sh`, so a value set once is
consistent everywhere. Two rules make the rest of this page readable:

- **Required** means `deploy.sh` refuses to run without it. Which values are required depends
  on mode: `--stack` does not need any `BIGIP_*`, and `WARDEN_DIRECTORY_MODE=external` needs
  the external-directory block instead of `LDAP_ADMIN_PW`/`TEST_USER_PW`.
- **Empty is meaningful** for a few keys: an empty `WARDEN_BIGIP_B_MGMT` selects the single
  standalone BIG-IP path rather than the HA pair, and an empty `BIGIP_PASS` means "inject it
  from the environment at run time" (the production pattern).

## `.env` (copy from `.env.example`, gitignored)
| Variable | Type | Example | Required | Effect |
|---|---|---|---|---|
| `WARDEN_HOST_IP` | IPv4 | `<this-host-ip>` | yes | Docker host / OpenBao address; the bundled LDAPS cert SAN must match it |
| `WARDEN_DIRECTORY_MODE` | enum `bundled`\|`external` | `bundled` | no | `bundled` runs Warden's own OpenLDAP; `external` uses your AD/LDAP and creates nothing in it ([directory.md](../directory.md)) |
| `WARDEN_ADMIN_GROUP_DN` | LDAP DN | `cn=bigip-admins,ou=groups,${BASE_DN}` | no | **The admin group: its members get Administrator, everyone else read-only.** Bundled creates it and adds the seeded privileged account; external expects it to exist and to contain your privileged accounts |
| `WARDEN_ADMIN_ROLE_ATTRIBUTE` | `attr=value` | derived from the group | no | _Advanced._ Overrides **how** membership is tested, for directories that cannot express it the derived way. Empty is correct unless the check below fails |
| `WARDEN_LDAP_HOST` | host/IPv4 | `${WARDEN_HOST_IP}` | external only | Your directory address |
| `WARDEN_LDAP_HOST_IP` | IPv4 | empty | no | Address to publish `WARDEN_LDAP_HOST` at **inside the OpenBao container**, for a name no nameserver can resolve (containers never read this host's `/etc/hosts`). Renders `docker-compose.override.yml`; leaving it empty removes that file again |
| `WARDEN_LDAP_PORT` / `WARDEN_LDAPS_PORT` | int | `389` / `636` | no | APM AAA query port / LDAPS port |
| `WARDEN_LDAP_SCHEMA` | enum `openldap`\|`ad` | `openldap` | no | `ad` resets `unicodePwd` and defaults the login attribute to `sAMAccountName` |
| `WARDEN_LDAP_CA_FILE` | path | bundled `certs/ca.crt` | external only | PEM of the CA that issued your LDAPS cert |
| `WARDEN_BIND_DN` | LDAP DN | `cn=bigip-bind,ou=svc,${BASE_DN}` | no | Read-only search bind the BIG-IP uses |
| `WARDEN_USER_SEARCH_BASE` | LDAP DN | `ou=people,${BASE_DN}` | no | Identity subtree (read-only) |
| `WARDEN_PRIV_SEARCH_BASE` | LDAP DN | `ou=users,${BASE_DN}` | no | Privileged accounts **whose passwords OpenBao rotates** — use a dedicated OU |
| `WARDEN_DIR_ADMIN_DN` / `_PW` | DN + string | bundled `cn=admin,${BASE_DN}` + `LDAP_ADMIN_PW` | external only | Account allowed to reset passwords on the privileged subtree |
| `WARDEN_LOGIN_ATTR` | string | `uid` (`sAMAccountName` when `ad`) | no | Attribute the cert CN is matched against and the BIG-IP logs in with. Set `cn` on AD — the default cannot serve both lookups there ([directory.md](../directory.md#active-directory)) |
| `WARDEN_PRIV_DN_ATTR` | string | `uid` (`cn` when `ad`) | no | RDN attribute of privileged-account DNs |
| `WARDEN_PRINCIPALS` | string list | _(none)_ | external only | CNs to issue client certs + static roles for |
| `BIGIP_MGMT` | IPv4 | `<bigip-a-mgmt-ip>` | yes | Target BIG-IP (bigipa) REST/management address |
| `BIGIP_USER` | string | `admin` | yes | BIG-IP account for `[AGENT-IF-ACCESS]` REST calls |
| `BIGIP_PASS` | string | _(empty)_ | at runtime | BIG-IP admin password. **Never stored** — for the demo set it here; production: inject from a secret manager (wrappers preserve an injected value across the `.env` source) |
| `BASE_DN` | LDAP DN | `dc=warden,dc=lab` | yes | Directory base DN |
| `LDAP_ADMIN_PW` | string | `<change-me>` | yes | OpenLDAP `cn=admin` password (lab only — rotate if shared) |
| `BIND_PW` | string | `<change-me>` | yes | `cn=bigip-bind` read-only bind password |
| `BAO_ADDR` | URL | `http://<this-host-ip>:8200` | yes | OpenBao API address |
| `BAO_TOKEN` | string | `root` (dev) / generated (prod) | yes | OpenBao token; production value is written by `openbao-init-unseal.sh` |
| `TEST_USER_PW` | string | `<change-me>` | for test users | Password for the alice/bob/carol test principals (lab only) |
| `WARDEN_CRED_MODE` | enum `ephemeral`\|`static` | `ephemeral` | no | Credential model for the operator/issue path (ADR 0006). `ephemeral` = throwaway leased account; `static` = rotate a standing account. Inline override wins over `.env` |
| `WARDEN_DOMAIN` | DNS domain | `warden.lab` | yes | Bundled: the OpenLDAP container's suffix and its LDAPS certificate CN/SAN, so it must correspond to `BASE_DN`. **Both modes**: the email SAN on issued client certificates (`<user>@<domain>`) |
| `WARDEN_DIR_ADMIN_PW` | string | bundled: `LDAP_ADMIN_PW` | external only | Password for `WARDEN_DIR_ADMIN_DN` — the account OpenBao binds as to reset privileged-account passwords |
| `WARDEN_BIGIP_B_MGMT` | IPv4 | _(empty)_ | no | HA peer's management address. **Empty selects the single-BIG-IP path**; setting it adds the peer's TMUI as a second webtop bookmark |
| `WARDEN_BIGIP_B_TMUI` | IPv4 | _(empty)_ | with peer | The peer's internal self-IP that APM proxies to for its TMUI. Required whenever `WARDEN_BIGIP_B_MGMT` is set |
| `WARDEN_SHADOW_A` | IPv4 | `192.0.2.5` | no | RFC 5737 TEST-NET façade for unit A's TMUI. Non-routable on purpose — APM rejects reserved addresses as portal targets, so an iRule steers the real last hop ([ADR 0003](../adr/0003-shadow-facade-portal-targets.md)). Keep as-is unless it collides |
| `WARDEN_SHADOW_B` | IPv4 | `192.0.2.6` | no | Façade for unit B's TMUI; used only when the HA peer is set |
| `WARDEN_P12_PASS` | string | `warden` | no | Export password for the browser client-certificate bundles (`clients/*.p12`) |
| `WARDEN_EPHEMERAL_ROLE` | string | `warden-admin` | no | OpenBao `ldap/creds/<role>` used in `ephemeral` mode |

## BIG-IP sys db / httpd knobs (set by the build)
| Setting | Value | Why |
|---|---|---|
| `tmm.tcl.rule.node.allow_loopback_addresses` | `true` | shadow VS iRule steers to a self-IP/loopback (ADR 0003) |
| `tmm.tcl.rule.connect.allow_loopback_addresses` | `true` | Portal Access proxy to an internal target |
| `httpd.matchclient` (sys db) | `false` | disable "Require Consistent Inbound IP"; proxied TMUI session survives SNAT source changes |
| `auth-pam-validate-ip` (sys httpd) | `off` | same, at the PAM layer — both units |
| external `external-self`/`ext_float` `allow-service` | none (`[]`) | no TMUI/SSH on the external VLAN (ADR 0003 hardening) |

### How the group becomes an entitlement
You configure a group; the BIG-IP evaluates an attribute. Warden bridges the two, and the
bridge differs by directory because the BIG-IP can only read what a **default** LDAP search
returns for the account it authenticated:

| Directory | How membership reaches the BIG-IP |
|---|---|
| Bundled OpenLDAP | `memberOf` there is *operational* — returned only when asked for by name, so the BIG-IP cannot see it. Warden therefore stamps the group's members with `employeeType=warden-admins` and maps on that. The group stays the source of truth |
| Active Directory | `memberOf` is a stored attribute returned by default, so the group is read directly and no stamp exists |
| 389DS / FreeIPA | depends on plugin and ACI configuration — `scripts/preflight-directory.sh` tests it |

Two consequences worth knowing. The group must contain the **privileged accounts** the
BIG-IP binds (`WARDEN_PRIV_SEARCH_BASE`), not the human identity entries in
`WARDEN_USER_SEARCH_BASE`; they are different objects and only the former is evaluated.
And if the bridge fails, it fails silently — everyone authenticates and lands read-only.
`deploy.sh` now checks this in bundled mode and `preflight-directory.sh` in external mode,
both probing as the BIG-IP's own read-only bind. Override
`WARDEN_ADMIN_ROLE_ATTRIBUTE` only when that check tells you the derived rule cannot work.

## Key BIG-IP object names (partition `/Common`, prefix `warden-apm`)
| Object | Name |
|---|---|
| Access profile | `warden-apm` |
| Test VIP | `<WARDEN_APM_VIP>:443` (`warden-apm-test-vs`) |
| AAA LDAP + pool | `warden-openldap-aaa`, `warden-openldap-aaa-pool` |
| Shadow façades | `warden-apm-shadow-a-vs` (192.0.2.5), `warden-apm-shadow-b-vs` (192.0.2.6) |
| Portal Access | `warden-apm-bigipa-tmui`, `warden-apm-bigipb-tmui` |
| Scoped-token data-group | `warden_openbao_dg` |

## OpenBao production config
`openbao/openbao-prod.hcl` (raft storage, HTTP listener :8200, audit-file device) plus
`docker-compose.prod.yml`. See [ADR 0005](../adr/0005-openbao-persisted-auto-unseal.md).
Do **not** add a `disable_mlock` line — it is a fatal error on this OpenBao 2.x build.
