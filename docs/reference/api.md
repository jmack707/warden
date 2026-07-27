# API / endpoint reference

The external interfaces this stack calls or exposes. Not a REST service of its own — these
are the endpoints the build and runtime paths depend on.

_Last validated: 2026-07 against OpenBao 2.x, Guacamole 1.6.0, TMOS 21.1.0._

## OpenBao (`http://<lab-host-ip>:8200`)
| Path | Method | Used by | Notes |
|---|---|---|---|
| `/v1/sys/health` | GET | install verification | `initialized`/`sealed` status |
| `/v1/auth/approle/login` | POST | lab AppRole (BIG-IP admin pw fetch) | returns a client token |
| `ldap/creds/pua-admin` | GET (read) | `issue-cred.sh` | mints an ephemeral leased LDAP user |
| `ldap/static-role/<CN>` | POST (write) | `configure-openbao-static.sh` | define a static role over an `ou=users` account |
| `ldap/static-cred/<CN>` | GET (read) | APM iRule fetch | current username + rotated password |
| `ldap/rotate-role/<CN>` | POST (write) | APM iRule fetch, `revoke-all.sh` | force a fresh password rotation |
| `sys/leases/revoke` | PUT | `revoke-cred.sh` | revoke an ephemeral lease → deletes the LDAP entry |

The APM iRule reaches OpenBao with a **scoped token** (policy `pua-apm-read`) that can read
only `ldap/static-cred/*` and `ldap/rotate-role/*`.

## Guacamole (`http://<lab-host-ip>:8080/guacamole`)
| Path | Method | Used by | Notes |
|---|---|---|---|
| `/api/tokens` | POST | `configure-guacamole.sh`, `revoke-all.sh` | `username`+`password` form → `authToken` |
| `/api/session/data/postgresql/activeConnections` | GET | `revoke-all.sh` | map of active-connection UUID → `{username, connectionIdentifier}` |
| `/api/session/data/postgresql/activeConnections` | PATCH | `revoke-all.sh` | kill: body `[{"op":"remove","path":"/<uuid>"}]` (not DELETE) |
| `/api/tokens/<token>` | DELETE | cleanup | revoke the admin token |

## BIG-IP (`https://<bigip-mgmt>/mgmt`)
| Path | Method | Used by | Notes |
|---|---|---|---|
| `/tm/auth/ldap/system-auth`, `/tm/auth/remote-role`, `/tm/auth/remote-user`, `/tm/auth/source` | POST/PATCH | `phase1-target-rest.sh` | Phase 1 auth config |
| `/tm/apm/...`, `/tm/ltm/...` | POST/PATCH/DELETE | `phase2-apm-dakota-rest.sh` | APM policy + LTM objects (in a transaction) |
| `/tm/net/self/~Common~<name>` | PATCH | hardening | `allow-service` lockdown |
| `/tm/util/bash` | POST | builds, `revoke-all.sh` | tmsh / `sessiondump` where REST has no route |

There is **no** clean REST route for deleting an APM session on 21.1 — use
`sessiondump --delete <key>` via `/tm/util/bash`.

## Data-plane (APM front door)
| Endpoint | Purpose |
|---|---|
| `https://10.2.20.50/` (test VIP) | client-cert auth → APM policy → webtop |
| `https://192.0.2.5/`, `https://192.0.2.6/` (façades) | shadow VS targets for Portal Access (ADR 0003); not directly browsed |
