# API / endpoint reference

_Last validated: 2026-07 against OpenBao 2.x, TMOS 21.1.0._

## Overview
Warden exposes no REST service of its own. It is an integration of three pre-existing
APIs, and this document is the contract it depends on: the **OpenBao HTTP API** (the
credential broker), the **BIG-IP iControl REST API** (everything the build and teardown
configure), and the **APM data plane** (the mutual-TLS front door an operator actually
browses). Knowing which of the three a failure came from is most of triage, because each
answers with a different vocabulary — OpenBao with JSON and a policy-aware `403`,
iControl REST with `409`/`404` that the scripts deliberately tolerate, and the data plane
sometimes with no HTTP status at all.

Three properties are worth holding in mind before reading the tables:

- **Every credential-path call is configuration, not code.** The APM front door reaches
  OpenBao from an iRule (`bigip/apm-openbao-fetch-static.irule`) using two plain HTTP
  requests over a TCP sideband; nothing in the path parses or stores a credential outside
  a session variable. See [../architecture.md](../architecture.md).
- **The token on the BIG-IP is deliberately weak.** The scoped token minted by
  `scripts/mint-apm-token.sh` may only read `ldap/static-cred/*` and write
  `ldap/rotate-role/*`. Anything else on the OpenBao API is denied to it by policy, and
  `GATE2A=1 scripts/configure-openbao-phase2.sh` proves that.
- **Site-specific values are placeholders here.** `<BIGIP_MGMT>`, `<WARDEN_APM_VIP>`,
  `<WARDEN_HOST_IP>`, `<WARDEN_SHADOW_A>` and `<WARDEN_SHADOW_B>` come from `.env` —
  see [configuration.md](configuration.md). The scripts that call these endpoints are
  documented in [cli.md](cli.md).

## Endpoints

### OpenBao HTTP API — `<BAO_ADDR>` (default `http://<WARDEN_HOST_IP>:8200`)
Most repo scripts reach OpenBao through `bao` inside the container
(`docker exec -e BAO_ADDR=http://127.0.0.1:8200 openbao bao …`), so the HTTP path below is
what the CLI calls on their behalf. Two callers speak HTTP directly: the APM iRule, and
`scripts/renew-apm-token.sh`.

| Path | Method | Reached by | What it does |
|---|---|---|---|
| `/v1/ldap/static-cred/<name>` | GET | APM fetch iRule; `bao read` in `scripts/configure-openbao-static.sh` and `scripts/lib/cred.sh` | returns the current username and OpenBao-held password of the privileged account behind static role `<name>` |
| `/v1/ldap/rotate-role/<name>` | POST | APM fetch iRule (immediately before the read), `scripts/revoke-all.sh --cn`, `cred_revoke`, `scripts/configure-openbao-static.sh` | forces an out-of-schedule rotation, which is both the "one-time password per session" mechanism and the revoke mechanism |
| `/v1/ldap/static-role/<name>` | POST | `scripts/configure-openbao-static.sh` | declares the static role over `<WARDEN_PRIV_DN_ATTR>=<name>,<WARDEN_PRIV_SEARCH_BASE>` with `rotation_period=24h` |
| `/v1/ldap/creds/<role>` | GET | ephemeral model only: `cred_issue`, `bigip/apm-openbao-fetch-ephemeral.irule`, the GATE 2A check | mints a throwaway leased LDAP account (`ldap/creds/warden-admin`); the response carries the `lease_id` used to revoke it |
| `/v1/ldap/config`, `/v1/ldap/role/<role>` | POST | `scripts/configure-openbao.sh` | engine bind configuration and the ephemeral role's creation/deletion/rollback LDIFs. The scoped APM token is denied both — that denial is the point |
| `/v1/sys/leases/revoke`, `/v1/sys/leases/revoke-prefix/<prefix>` | PUT | `bao lease revoke` in `scripts/lib/cred.sh` and `scripts/revoke-all.sh --lease`; `bao lease revoke -prefix ldap/creds/warden-admin` in `teardown.sh` | revokes an ephemeral lease, which runs the deletion LDIF and removes the account from the directory |
| `/v1/auth/token/create` | POST | `bao token create` in `scripts/mint-apm-token.sh` and `scripts/configure-openbao-phase2.sh` | mints the periodic, policy-scoped token the iRule presents |
| `/v1/auth/token/renew-self` | POST | `scripts/renew-apm-token.sh`, by direct `curl` | extends that token's period; the script asserts `.auth.lease_duration` came back |
| `/v1/sys/policies/acl/<name>` | POST | `bao policy write` (`warden-apm-static`, `warden-apm-read`) | writes the scoping policy the token is bound to |
| `/v1/sys/policies/password/<name>` | POST | `scripts/configure-openbao.sh` | registers the `warden-ephemeral` password policy |
| `/v1/sys/mounts/ldap` | POST/DELETE | `bao secrets enable ldap` (`scripts/configure-openbao.sh`), `bao secrets disable ldap` (`teardown.sh`) | mounts and unmounts the LDAP secrets engine |
| `/v1/sys/seal-status` | GET | `bao status -format=json` in `scripts/openbao-init-unseal.sh` | the `initialized` / `sealed` pair the boot-time unseal logic branches on |
| `/v1/sys/init`, `/v1/sys/unseal` | PUT | `bao operator init` / `bao operator unseal` in `scripts/openbao-init-unseal.sh` | the persisted-storage seal lifecycle ([ADR 0005](../adr/0005-openbao-persisted-auto-unseal.md)) |

The two calls the iRule makes are the whole runtime credential path, in order: `POST
/v1/ldap/rotate-role/<CN>` then `GET /v1/ldap/static-cred/<CN>`, both carrying
`X-Vault-Token` from the `warden_openbao_dg` data group. If either fails, the session still
reaches the webtop with an empty password — see the websso row in
[../operations/troubleshooting.md](../operations/troubleshooting.md#symptom-index).

`/v1/auth/approle/login` is not called by this repo, but it is the endpoint to expect on
the operator side: where `BIGIP_PASS` is injected from a secret manager rather than stored
in `.env`, a wrapper authenticates there first and pipes the password in. The wrappers
`bigip/run-apm-build.sh` and `scripts/revoke-all.sh` preserve an injected `BIGIP_PASS`
across their `.env` source precisely so that pattern works.

### BIG-IP iControl REST — `https://<BIGIP_MGMT>/mgmt`
Basic auth as `<BIGIP_USER>`; every script uses `curl -sk` because the management
certificate is the device's self-signed one.

| Path | Method | Used by | Notes |
|---|---|---|---|
| `/shared/file-transfer/uploads/<name>` | POST | `bigip/phase1-target-rest.sh` | chunked binary upload of a CA PEM into `/var/config/rest/downloads/` |
| `/tm/sys/file/ssl-cert`, `/tm/sys/file/ssl-cert/<name>` | GET/POST/PATCH | `bigip/phase1-target-rest.sh` | create-or-update the trust anchor from the uploaded file. GET first, because an existing object still holds the *old* CA and stale client-cert trust fails closed |
| `/tm/auth/ldap`, `/tm/auth/ldap/system-auth` | GET/POST/PATCH | `bigip/phase1-target-rest.sh` | LDAPS system authentication against the **privileged** subtree |
| `/tm/auth/remote-user` | PATCH | `bigip/phase1-target-rest.sh`, `teardown.sh` | `defaultRole` — `guest` while Warden is deployed, restored to `no-access` on teardown |
| `/tm/auth/remote-role/role-info/warden_admins` | GET/POST/PATCH | `bigip/phase1-target-rest.sh` | the single rule that grants `administrator`, matching `WARDEN_ADMIN_ROLE_ATTRIBUTE` ([ADR 0004](../adr/0004-authorization-on-bigip-remote-role.md)) |
| `/tm/auth/source` | PATCH | `bigip/phase1-target-rest.sh` (`ldap`), `teardown.sh` (`local`, first) | flips the device's auth source. `admin`/`root` stay local, so neither direction can lock you out |
| `/tm/ltm/profile/client-ssl`, `/tm/ltm/virtual`, `/tm/ltm/rule`, `/tm/ltm/pool` | POST | `bigip/apm-build.sh` | the front-door VIP, the shadow façade VSs, the fetch/referer-strip/node iRules |
| `/tm/ltm/data-group/internal` | POST | `bigip/apm-build.sh` | `warden_openbao_dg`, holding the scoped token — never inline in the iRule |
| `/tm/ltm/data-group/internal/warden_openbao_dg` | GET | `scripts/renew-apm-token.sh` | reads the live token back out; the datagroup is the source of truth the iRule uses |
| `/tm/apm/policy/agent/{variable-assign,aaa-ldap,irule-event,resource-assign,ending-allow,ending-deny}` | POST | `bigip/apm-build.sh` | the per-item policy agents |
| `/tm/apm/policy/customization-group` | POST | `bigip/apm-build.sh` | the presentation groups an access profile requires |
| `/tm/apm/policy/policy-item/`, `/tm/apm/policy/access-policy/`, `/tm/apm/profile/access/` | POST | `bigip/apm-build.sh`, inside the transaction | the policy graph and the profile that binds it |
| `/tm/apm/sso/form-based`, `/tm/apm/resource/webtop`, `/tm/apm/resource/portal-access`, `/tm/apm/profile/connectivity` | POST | `bigip/apm-build.sh` | TMUI form SSO, webtop, portal bookmarks, connectivity profile |
| `/tm/transaction`, `/tm/transaction/<id>` | POST/PATCH | `bigip/apm-build.sh` | opens a transaction, then commits with `{"state":"VALIDATING"}` so a half-applied policy graph cannot persist |
| `/tm/util/bash` | POST | `bigip/phase1-target-rest.sh`, `bigip/apm-build.sh`, `scripts/revoke-all.sh`, `teardown.sh` | the escape hatch where REST has no route: the AAA LDAP object (21.x requires a pool), portal item headers, `sys db` flags, and `sessiondump` |
| `/tm/sys/config` | POST | `bigip/phase1-target-rest.sh`, `teardown.sh` | `{"command":"save"}` — auth changes are not persistent until saved |
| `/tm/net/self/~Common~<name>` | PATCH | operator hardening step | `{"allowService":[]}` closes TMUI and SSH on the external VLAN. The literal string `none` is rejected; the empty list is what works ([ADR 0003](../adr/0003-shadow-facade-portal-targets.md)) |
| every path in `bigip/lib/objects.sh` | DELETE | `bigip/apm-build.sh` (mutable graph, before rebuild), `teardown.sh` | one shared object list, so build and teardown cannot drift |

There is **no** usable REST route for deleting an APM session on 21.1 —
`/tm/apm/access-session` does not exist and `tmsh show apm access-session` is gone. The
working verb is `sessiondump --delete <key>` through `/tm/util/bash`, which is why
`scripts/revoke-all.sh` shells out.

### APM data plane — the front door
| Endpoint | Purpose |
|---|---|
| `https://<WARDEN_APM_VIP>/` | the VIP operators browse. Client-certificate TLS, then the access policy: cert auth → extract CN → LDAP identity query → OpenBao fetch → SSO credentials → resource assign → Allow |
| `https://<WARDEN_APM_VIP>/vdesk/webtop.eui` | the webtop a permitted session lands on — the success signal in the verification matrix |
| `https://<WARDEN_APM_VIP>/vdesk/my.acl.php3` | the portal bookmark launcher; an `errorcode=` query string here is APM refusing the target rather than a transport failure |
| `https://<WARDEN_SHADOW_A>/`, `https://<WARDEN_SHADOW_B>/` | the shadow façade VSs (RFC 5737 addresses by default). Portal Access resources target these because APM rejects cluster-reserved addresses; an iRule `node` steers the real last hop. Not browsed directly ([ADR 0003](../adr/0003-shadow-facade-portal-targets.md)) |

Mutual TLS does not survive a TLS-terminating proxy, so the data plane must be exercised
from a host with layer-3 reachability to the VIP.

## Status codes
The codes below are the ones this repo's flows actually turn on. The scripts treat some
non-2xx answers as success on purpose, and that is not laxness — it is what makes an
additive build and an idempotent teardown possible.

### OpenBao
| Code | Where | Operational meaning |
|---|---|---|
| `200` with a JSON body | `GET /v1/ldap/static-cred/<name>`, `GET /v1/ldap/creds/<role>` | the credential is in `.data`. The iRule's regex over the response body is what extracts `"password"`, so a `200` whose body does not contain that key sets `session.custom.warden.fetch_err` to `parse-failed` and the session continues with no password |
| `204 No Content` | `POST /v1/ldap/rotate-role/<name>` | rotation succeeded. There is deliberately no body — the new password is not returned here; the caller reads it back from `static-cred`. Treat `204` as "the previous password is now dead" |
| `403 Permission denied` | any path outside the scoped token's policy | the token is doing its job. GATE 2A asserts exactly this for `ldap/config` and `sys/policies/acl/root`. A `403` on `static-cred` or `rotate-role`, though, means the policy or the token is wrong |
| error body naming `LDAP Result Code 32 "No Such Object"` | rotate or static-cred for a `<name>` | the privileged account the static role points at does not exist. OpenBao is reporting the directory's answer, not its own state — usually seeding failed earlier |
| any response missing `.auth.lease_duration` | `POST /v1/auth/token/renew-self` | the periodic token is already dead. `scripts/renew-apm-token.sh` exits non-zero here; unnoticed, this is the silent cause of empty SSO passwords a month after deployment |

### iControl REST
| Code | Where | Operational meaning |
|---|---|---|
| `200` / `201` | any create or modify | applied. The build prints the code for every call, so a transcript is a usable audit trail |
| `409 Conflict` | additive `POST`s in `bigip/apm-build.sh` | the object already exists. The `add` helper accepts `200|201|409` and fails on anything else, which is what lets the build re-run without a teardown of the immutable objects |
| `404 Not Found` | `DELETE` in `teardown.sh`, and the pre-rebuild deletes in `bigip/apm-build.sh` | already absent, which is the desired end state. A teardown transcript of `404`s is a clean teardown, not a broken one — after `./teardown.sh --all`, every line *should* be `404` or absent |
| `401 Unauthorized` | a remote user calling any `/mgmt/tm/...` path | ambiguous by design, and the trap worth knowing. F5's **Guest** role is denied iControl REST outright, so a read-only remote user gets `401` even though the credential was correct and TMUI would have worked. A genuinely wrong injected password produces the same `401`. Because the code cannot separate the two, confirm the role from the target's `/var/log/secure` `pam_bigip_authz` `level=` line instead of a REST probe |
| `>= 400` from `phase1-target-rest.sh` | any Phase 1 call | fatal. Unlike the APM build, Phase 1 has no tolerated failures: its `req` helper prints the body and exits, because a half-configured auth source is worse than none |
| a commit response without `"state":"COMPLETED"` | `PATCH /tm/transaction/<id>` | the graph was rejected as a unit and nothing was applied. Read the printed body — the failing policy item is named in it |

### Data plane
| Result | Operational meaning |
|---|---|
| `200` ending at the webtop | the full path worked: certificate accepted, identity found, credential fetched, SSO ready |
| TLS handshake failure — `curl` exit `56`, HTTP status `000` | the client certificate was rejected by the client-SSL profile. There is **no** HTTP status because the connection never became HTTP; the access policy was never consulted. This is the expected outcome for an expired or untrusted certificate, and it is the strongest result in the matrix — the front door failed closed before any policy logic ran |
| an HTTP response that lands on the deny/logout ending instead of the webtop | the certificate was accepted — the handshake completed — but the access policy denied. The decision is in `/var/log/apm`, keyed by session id. A deny on the *first* attempt right after a rebuild (`errorcode=19`) is policy-apply lag: retry once |
| `200` at the webtop, then a TMUI login form that does not submit | the credential fetch or the SSO injection failed. The transport is fine; look at OpenBao and the datagroup token, not at TLS |

## Content types
| Header / type | Where | Why it matters |
|---|---|---|
| `application/json` | every iControl REST write (`-H 'Content-Type: application/json'`) and every OpenBao response | both APIs are JSON-only for the paths Warden uses. Omitting the header on an iControl `POST`/`PATCH` gets the body rejected, so every helper in the build sets it explicitly |
| `application/octet-stream` plus `Content-Range: 0-<size-1>/<size>` | `POST /mgmt/shared/file-transfer/uploads/<name>` in `bigip/phase1-target-rest.sh` | the CA install is a raw binary upload, not JSON. The endpoint is a chunked-transfer API: `Content-Range` is mandatory and must describe the whole file (`stat -c%s`) for a single-chunk upload. Get it wrong and the upload appears to succeed while the resulting file is truncated, which surfaces much later as a client-cert trust failure |
| `X-Vault-Token: <token>` | every OpenBao HTTP call — the iRule's two requests and `scripts/renew-apm-token.sh` | OpenBao's only authentication mechanism here. The iRule reads the value from the `warden_openbao_dg` data group rather than embedding it, so rotating the token is a datagroup update and needs no policy rebuild |
| `X-F5-REST-Coordination-Id: <transId>` | every policy-item `POST` inside `bigip/apm-build.sh`'s transaction | the header is what enrolls a call in the open transaction instead of applying it immediately. A policy-graph `POST` that loses this header applies alone, which is how you get a device holding half a graph |
| `Content-Length: 0` | the iRule's `POST /v1/ldap/rotate-role/<CN>` | the rotate call has no body, and the sideband speaks raw HTTP/1.1 with `Connection: close`. Without an explicit zero length OpenBao waits for a body that never arrives and the fetch times out inside the session |
| basic auth (`-u <BIGIP_USER>:<BIGIP_PASS>`) | every iControl REST call | there is no token exchange on the management plane. `BIGIP_PASS` ships empty in `.env` on purpose so it can be injected at run time — see [configuration.md](configuration.md) |
