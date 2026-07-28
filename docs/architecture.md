# Warden — Architecture

_Last validated: 2026-07 against TMOS 21.1.0, OpenBao 2.x, OpenLDAP (osixia) 1.5.0._

Placeholders below (`<...>`) are the values a customer sets in `.env`; the reference
build used a Dakota lab. Design decisions are captured in [adr/](adr/).

## Components
| Component | Role |
|---|---|
| Docker host `<WARDEN_HOST_IP>` | Warden stack: **OpenBao** (broker/rotator, `:8200`), **OpenLDAP** (LDAPS `:636`) |
| BIG-IP A `<BIGIP_MGMT>` (TMOS 21.x, APM licensed) | APM front door: cert auth, LDAP query, OpenBao credential injection, portal/webtop |
| BIG-IP B (optional, `<WARDEN_BIGIP_B_MGMT>`) | HA peer; a second portal target. APM `/Common` objects sync from A |

Single standalone BIG-IP is the default; setting the peer address in `.env` adds the HA
path (a second bookmark to the peer's TMUI).

## Identity / privilege split (LDAP)
- **ou=people** — identity entries (the demo seeds alice.admin, bob.user, carol.expired).
  The cert CN maps here.
- **ou=users** — privileged *access* accounts whose password OpenBao owns/rotates and the
  BIG-IP validates by LDAP bind. `employeeType=warden-admins` marks admins.
- **cn=bigip-admins,ou=groups** — the admin group.
- `cn=bigip-bind,ou=svc` — the BIG-IP search/bind account (read ACL on ou=users, never
  reads `userPassword`).

## Request flow (browser → privileged TMUI)
1. **Client cert** (Warden CA) at the APM VIP `<WARDEN_APM_VIP>` → APM extracts the CN.
   Invalid/expired cert → TLS reject at the handshake.
2. **LDAP query** `(uid=<CN>)` against OpenLDAP — identity-only (authz is on the BIG-IP,
   [ADR 0004](adr/0004-authorization-on-bigip-remote-role.md)). Exists → continue; else Deny.
3. **OpenBao fetch** — an APM iRule sidebands to OpenBao with a scoped token, rotates
   `ldap/rotate-role/<CN>` then reads `ldap/static-cred/<CN>`; the fresh one-time password
   lands in `session.custom.warden.password`.
4. **Webtop** with a Portal Access bookmark per BIG-IP, delivered via **shadow façades**
   ([ADR 0003](adr/0003-shadow-facade-portal-targets.md)): a non-routable TEST-NET IP whose
   shadow VS steers the last hop with an iRule `node` (127.0.0.1 for the local unit, the
   peer's internal self-IP for the HA peer). Façades dodge APM's reserved-address guard.
5. **Form SSO** (websso) injects CN + fetched password into the target's `/tmui/logmein.html`.
6. **Target BIG-IP authorizes** by LDAP bind + remote-role
   ([ADR 0004](adr/0004-authorization-on-bigip-remote-role.md)):
   `employeeType=warden-admins` → **Administrator**, otherwise the default → **Guest /
   read-only**.

## Authorization outcome
| Principal | Cert | APM | BIG-IP role |
|---|---|---|---|
| alice.admin | valid | Allow → webtop | Administrator |
| bob.user | valid | Allow → webtop | Guest (read-only) |
| carol.expired | expired | TLS reject | — |

## Credential models
Selectable by `WARDEN_CRED_MODE` ([ADR 0006](adr/0006-configurable-credential-model.md)):
- **static** — OpenBao rotates a standing account's password (username = the identity CN);
  the user never sees it. This is what the APM injection flow uses.
- **ephemeral** — OpenBao mints a throwaway leased account (random username, deleted at
  TTL); the operator receives it and logs in with their own SSH client.

Both are fronted by one abstraction (`scripts/lib/cred.sh`); a credential's revoke handle
encodes its model, so revocation works without knowing the mode.

## Session termination (kill switch)
`scripts/revoke-all.sh` — two independent cuts: OpenBao rotate/lease-revoke (future logins)
and `sessiondump --delete` (a live APM/TMUI session). An already-established SSH session is
ended by the operator on the box; lease revoke stops the *next* login.

## Security posture
- Portal targets are non-routable façades; TMUI is not exposed on the external VLAN
  (external self-IP `allow-service none`).
- TMUI session-pinning (`httpd.matchclient`, `auth-pam-validate-ip`) off so proxied
  sessions survive SNAT source changes.
- `admin`/`root` on the BIG-IP stay local (never LDAP) — the recovery path.
- APM → OpenBao uses a least-privilege scoped token (policy `warden-apm-read`: reads only
  `ldap/static-cred/*` + `ldap/rotate-role/*`).

## Trust boundaries
- **Client → APM VIP:** X.509 client cert (Warden CA), `peerCertMode require`. An
  untrusted/expired cert fails at TLS — nothing downstream runs.
- **OpenBao → OpenLDAP:** OpenBao is the only writer of `userPassword`; the BIG-IP bind
  account can read attributes but not `userPassword`.
- **OpenBao at rest:** with auto-unseal, the unseal key lives on the Docker host, so host
  root can unseal. Accepted for the demo; production uses a managed seal / manual unseal.
- **admin/root on the BIG-IP are local** — recovery if the directory or OpenBao is down.

## Constraints
- APM AAA LDAP requires an LTM **pool** on 21.x (a bare server address is rejected).
- APM Portal Access refuses to proxy to any cluster-reserved address — targets must be
  non-reserved façade IPs ([ADR 0003](adr/0003-shadow-facade-portal-targets.md)).
- OpenBao 2.x dev mode is in-memory (lost on container recreate); production uses raft
  ([ADR 0005](adr/0005-openbao-persisted-auto-unseal.md)).
