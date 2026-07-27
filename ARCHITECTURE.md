# PUA-OSS — As-Built Architecture (Dakota)

The living picture of what is actually deployed, as of 2026-07-27. RUNBOOK.md is the
original two-phase build plan; this file records where the running system landed after
deviations 1–16 (see DEVIATIONS.md for the why of each).

## Components
| Host | Role |
|---|---|
| pua-oss VM (10.2.20.30, VLAN 73) | Docker stack: **OpenBao** (raft-persisted, sealed/auto-unseal, :8200 HTTP internal), **OpenLDAP** (LDAPS :636), **Guacamole** (guac/guacd/postgres, :8080) |
| bigipa (10.2.1.5 mgmt / 10.2.20.5 internal / 10.2.10.5 ext, TMOS 21.1.0) | APM front door: cert auth, LDAP query, OpenBao credential injection, portal/webtop |
| bigipb (10.2.1.6 / 10.2.20.6 / 10.2.10.6) | HA peer; a portal target (its own TMUI). APM /Common objects sync from A |

## Identity / privilege split (LDAP)
- **ou=people** — identity entries (alice.admin, bob.user, carol.expired). Cert CN maps here.
- **ou=users** — privileged *access* accounts whose password OpenBao owns/rotates and the
  BIG-IP validates by LDAP bind. `employeeType=pua-admins` marks admins (alice.admin has it;
  bob.user does not).
- **cn=bigip-admins,ou=groups** — the admin group (drove the old APM filter; retained).
- `cn=bigip-bind,ou=svc` — the BIG-IP search/bind account (read ACL on ou=users, no password read).

## Request flow (browser → privileged TMUI)
1. **Client cert** (PUA Lab CA) at the APM VIP 10.2.20.50 → APM extracts the CN.
   Invalid/expired cert (carol) → TLS reject at the handshake.
2. **LDAP query** `(uid=<CN>)` against OpenLDAP — identity-only (authz is on the BIG-IP now,
   deviation 13). Exists → continue; else Deny.
3. **OpenBao fetch** — APM iRule sidebands to OpenBao (:8200) with a scoped token, rotates
   `ldap/rotate-role/<CN>` then reads `ldap/static-cred/<CN>`; the fresh one-time password
   lands in `session.custom.pua.password`.
4. **Webtop** (full) with two Portal Access bookmarks, delivered via **shadow façades**
   (deviation 12): 192.0.2.5 → this unit's own TMUI (iRule `node 127.0.0.1`), 192.0.2.6 →
   bigipb TMUI over the internal VLAN. Façades dodge APM's reserved-address guard;
   TMUI is NOT exposed on the external VLAN (deviation 14).
5. **Form SSO** (websso) injects CN + fetched password into the target's /tmui/logmein.html.
6. **Target BIG-IP authorizes** by LDAP bind + remote-role (deviation 13):
   employeeType=pua-admins → **Administrator** (alice), otherwise default → **Guest /
   read-only** (bob).

## Authorization outcome
| Principal | Cert | APM | BIG-IP role |
|---|---|---|---|
| alice.admin | valid | Allow → webtop | Administrator |
| bob.user | valid | Allow → webtop | Guest (read-only) |
| carol.expired | expired | TLS reject | — |

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

## Known follow-ons (not yet done)
- OpenBao listener is HTTP on the internal VLAN; TLS on :8200 cascades into the APM iRule
  sideband + scoped-token flow — deferred.
- Operator browser click-through of both bookmarks (alice full-admin, bob read-only) is the
  last human confirmation.
