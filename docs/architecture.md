# Warden — Architecture (Dakota)

_Last validated: 2026-07 against TMOS 21.1.0, OpenBao 2.x, OpenLDAP (osixia) 1.5.0,
Guacamole 1.6.0._

The living picture of what is actually deployed. [../RUNBOOK.md](../RUNBOOK.md) is the
original two-phase build plan; this file records where the running system landed after
deviations 1–16 ([../DEVIATIONS.md](../DEVIATIONS.md) for the why of each, distilled into
[adr/](adr/)).

## Components
| Host | Role |
|---|---|
| warden VM (10.2.20.30, VLAN 73) | Docker stack: **OpenBao** (raft-persisted, sealed/auto-unseal, :8200 HTTP internal), **OpenLDAP** (LDAPS :636), **Guacamole** (guac/guacd/postgres, :8080) |
| bigipa (10.2.1.5 mgmt / 10.2.20.5 internal / 10.2.10.5 ext, TMOS 21.1.0) | APM front door: cert auth, LDAP query, OpenBao credential injection, portal/webtop |
| bigipb (10.2.1.6 / 10.2.20.6 / 10.2.10.6) | HA peer; a portal target (its own TMUI). APM /Common objects sync from A |

## Identity / privilege split (LDAP)
- **ou=people** — identity entries (alice.admin, bob.user, carol.expired). Cert CN maps here.
- **ou=users** — privileged *access* accounts whose password OpenBao owns/rotates and the
  BIG-IP validates by LDAP bind. `employeeType=warden-admins` marks admins (alice.admin has it;
  bob.user does not).
- **cn=bigip-admins,ou=groups** — the admin group (drove the old APM filter; retained).
- `cn=bigip-bind,ou=svc` — the BIG-IP search/bind account (read ACL on ou=users, no password read).

## Request flow (browser → privileged TMUI)
1. **Client cert** (Warden Lab CA) at the APM VIP 10.2.20.50 → APM extracts the CN.
   Invalid/expired cert (carol) → TLS reject at the handshake.
2. **LDAP query** `(uid=<CN>)` against OpenLDAP — identity-only (authz is on the BIG-IP now,
   deviation 13). Exists → continue; else Deny.
3. **OpenBao fetch** — APM iRule sidebands to OpenBao (:8200) with a scoped token, rotates
   `ldap/rotate-role/<CN>` then reads `ldap/static-cred/<CN>`; the fresh one-time password
   lands in `session.custom.warden.password`.
4. **Webtop** (full) with two Portal Access bookmarks, delivered via **shadow façades**
   (deviation 12): 192.0.2.5 → this unit's own TMUI (iRule `node 127.0.0.1`), 192.0.2.6 →
   bigipb TMUI over the internal VLAN. Façades dodge APM's reserved-address guard;
   TMUI is NOT exposed on the external VLAN (deviation 14).
5. **Form SSO** (websso) injects CN + fetched password into the target's /tmui/logmein.html.
6. **Target BIG-IP authorizes** by LDAP bind + remote-role (deviation 13):
   employeeType=warden-admins → **Administrator** (alice), otherwise default → **Guest /
   read-only** (bob).

## Authorization outcome
| Principal | Cert | APM | BIG-IP role |
|---|---|---|---|
| alice.admin | valid | Allow → webtop | Administrator |
| bob.user | valid | Allow → webtop | Guest (read-only) |
| carol.expired | expired | TLS reject | — |

## Credential models
Credentials come two ways, selectable by `WARDEN_CRED_MODE` on the operator/issue path
([ADR 0006](adr/0006-configurable-credential-model.md)):
- **ephemeral** — OpenBao mints a throwaway leased account (random username, deleted at
  TTL). Consumed by the operator over SSH (Guacamole today, webssh later).
- **static** — OpenBao rotates a standing account's password (username = the identity CN).
  This is the model the APM injection flow uses (the user never sees the password).

Both are fronted by one abstraction (`scripts/lib/cred.sh`); a credential's revoke handle
encodes its model, so revocation works without knowing the mode.

## Session termination (kill switch)
`scripts/revoke-all.sh` (Nora wrapper `bigip/run-revoke.sh`) — three independent cuts
(deviation 15): OpenBao rotate/lease-revoke (future logins), `sessiondump --delete` (live
APM/TMUI session), Guac PATCH-remove (live SSH tunnel).

## Security posture / hardening
- External-VLAN self-IPs: `allow-service none` — no TMUI/SSH exposure (deviation 14).
- Session-pinning (httpd.matchclient, auth-pam-validate-ip) off both units for proxied
  sessions (deviation 11).
- OpenBao: persisted, sealed, generated root token, audit-file device; key custody = AUTO
  (VM-local key file + systemd unseal), VM is the trust boundary (deviation 16).
- admin/root stay local on both BIG-IPs (never LDAP) — recovery path.

## Trust boundaries
- **Client → APM VIP (10.2.20.50):** authenticated by X.509 client cert (Warden Lab CA) with
  `peerCertMode require`. An untrusted/expired cert fails at the TLS handshake — nothing
  downstream runs.
- **APM → OpenBao (:8200):** a least-privilege scoped token (policy `warden-apm-read`, reads
  only `ldap/static-cred/*` + `ldap/rotate-role/*`), carried in an internal data-group.
  HTTP, on the internal VLAN only.
- **OpenBao → OpenLDAP:** OpenBao owns the `userPassword` of ou=users accounts and is the
  only writer; the BIG-IP bind account can read attributes but not `userPassword`.
- **VM host = trust boundary for OpenBao at rest:** AUTO-unseal keeps the unseal key in a
  root-only file on the VM. Root on the VM can unseal OpenBao. Accepted for the lab.
- **admin/root on both BIG-IPs are local, never LDAP** — the recovery path if the directory
  or OpenBao is unavailable.

## Constraints
- APM AAA LDAP requires an LTM **pool** on 21.x (a bare server address is rejected).
- `memberOf` is an operational attribute: not returned by a default LDAP query, but it can
  be filtered on. (Authorization no longer relies on it — see [adr/0004](adr/0004-authorization-on-bigip-remote-role.md).)
- APM Portal Access refuses to proxy to any cluster-reserved address (self-IPs, mgmt,
  device-trust). Portal targets must be non-reserved façade IPs — see
  [adr/0003](adr/0003-shadow-facade-portal-targets.md).
- OpenBao 2.x dev mode is in-memory (lost on container recreate); production uses raft —
  see [adr/0005](adr/0005-openbao-persisted-auto-unseal.md).

## Known follow-ons (not yet done)
- OpenBao listener is HTTP on the internal VLAN; TLS on :8200 cascades into the APM iRule
  sideband + scoped-token flow — deferred (tracked in [upgrade.md](upgrade.md)).
- Operator browser click-through of both bookmarks (alice full-admin, bob read-only) is the
  last human confirmation — see [operations/runbooks/browser-verify.md](operations/runbooks/browser-verify.md).
