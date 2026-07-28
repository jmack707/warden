# Configuration reference

Every setting that governs the stack: `.env` variables, the sys `db`/httpd knobs the build
sets on the BIG-IP, and the key BIG-IP object names. Site-specific values use the
`<placeholder>` form.

_Last validated: 2026-07._

## `.env` (copy from `.env.example`, gitignored)
| Variable | Type | Default (lab) | Required | Effect |
|---|---|---|---|---|
| `LAB_HOST_IP` | IPv4 | `10.2.20.30` | yes | Docker host / OpenBao+LDAP+Guac address; the LDAPS cert SAN must match it |
| `BIGIP_MGMT` | IPv4 | `10.2.1.5` | yes | Target BIG-IP (bigipa) REST/management address |
| `BIGIP_USER` | string | `admin` | yes | BIG-IP account for `[AGENT-IF-ACCESS]` REST calls |
| `BIGIP_PASS` | string | _(empty)_ | at runtime | BIG-IP admin password. **Never stored** — injected by the AppRole wrapper; scripts preserve an injected value across the `.env` source |
| `BASE_DN` | LDAP DN | `dc=warden,dc=lab` | yes | Directory base DN |
| `LDAP_ADMIN_PW` | string | `AdminPw1!` | yes | OpenLDAP `cn=admin` password (lab only — rotate if shared) |
| `BIND_PW` | string | `BindPw1!` | yes | `cn=bigip-bind` read-only bind password |
| `BAO_ADDR` | URL | `http://10.2.20.30:8200` | yes | OpenBao API address |
| `BAO_TOKEN` | string | `root` (dev) / generated (prod) | yes | OpenBao token; production value is written by `openbao-init-unseal.sh` |
| `TEST_USER_PW` | string | `TestUser1!` | for test users | Password for the alice/bob/carol test principals (lab only) |
| `WARDEN_CRED_MODE` | enum `ephemeral`\|`static` | `ephemeral` | no | Credential model for the operator/issue path (ADR 0006). `ephemeral` = throwaway leased account; `static` = rotate a standing account. Inline override wins over `.env` |
| `WARDEN_EPHEMERAL_ROLE` | string | `warden-admin` | no | OpenBao `ldap/creds/<role>` used in `ephemeral` mode |
| `GUAC_ADMIN_PW` | string | `PuaGuac2026!` | for Guac | guacadmin password (rotated from the rejected default by `configure-guacamole.sh`) |

## BIG-IP sys db / httpd knobs (set by the build)
| Setting | Value | Why |
|---|---|---|
| `tmm.tcl.rule.node.allow_loopback_addresses` | `true` | shadow VS iRule steers to a self-IP/loopback (ADR 0003) |
| `tmm.tcl.rule.connect.allow_loopback_addresses` | `true` | Portal Access proxy to an internal target |
| `httpd.matchclient` (sys db) | `false` | disable "Require Consistent Inbound IP"; proxied TMUI session survives SNAT source changes |
| `auth-pam-validate-ip` (sys httpd) | `off` | same, at the PAM layer — both units |
| external `external-self`/`ext_float` `allow-service` | none (`[]`) | no TMUI/SSH on the external VLAN (ADR 0003 hardening) |

## Key BIG-IP object names (partition `/Common`, prefix `warden-apm`)
| Object | Name |
|---|---|
| Access profile | `warden-apm` |
| Test VIP | `10.2.20.50:443` (`warden-apm-test-vs`) |
| AAA LDAP + pool | `warden-openldap-aaa`, `warden-openldap-aaa-pool` |
| Shadow façades | `warden-apm-shadow-a-vs` (192.0.2.5), `warden-apm-shadow-b-vs` (192.0.2.6) |
| Portal Access | `warden-apm-bigipa-tmui`, `warden-apm-bigipb-tmui` |
| Scoped-token data-group | `warden_openbao_dg` |

## OpenBao production config
`openbao/openbao-prod.hcl` (raft storage, HTTP listener :8200, audit-file device) plus
`docker-compose.prod.yml`. See [ADR 0005](../adr/0005-openbao-persisted-auto-unseal.md).
Do **not** add a `disable_mlock` line — it is a fatal error on this OpenBao 2.x build.
