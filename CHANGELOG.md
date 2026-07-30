# Changelog

Notable changes to Warden. Dates are absolute. Engineering notes are in
[DEVIATIONS.md](DEVIATIONS.md); decisions in [docs/adr/](docs/adr/).

## 2026-07-29
### Added
- **Bring your own directory.** `WARDEN_DIRECTORY_MODE=external` points Warden at an
  existing AD / FreeIPA / LDAP instead of the bundled OpenLDAP, and it creates nothing
  there. Identity, privileged-account and admin-group subtrees are separately configurable;
  `WARDEN_LDAP_SCHEMA=ad` switches password resets to `unicodePwd` and login to
  `sAMAccountName`. New `scripts/preflight-directory.sh` validates the LDAPS chain, both
  binds, the group and the subtrees read-only before anything on the BIG-IP is touched, and
  `deploy.sh` refuses to continue if it fails. Guide: [docs/directory.md](docs/directory.md).
- **The BIG-IP admin group is now configuration**, not a constant: `WARDEN_ADMIN_GROUP_DN`
  plus `WARDEN_ADMIN_ROLE_ATTRIBUTE` (defaults preserve the seeded `employeeType` mapping in
  bundled mode, and use real `memberOf` membership in external mode).
- **`./teardown.sh`** — removes the BIG-IP configuration and/or the local stack in reverse
  dependency order, with `--dry-run`, `--purge` and a confirmation prompt. Flips the auth
  source back to local *before* deleting the LDAP config, restores `remote-user` to
  `no-access`, and never touches an external directory. The object list is shared with
  `apm-build.sh` (`bigip/lib/objects.sh`) so build and teardown cannot drift.
- `scripts/gen-client-certs.sh` issues Warden-CA client certs for arbitrary principals
  (external mode, where Warden does not seed users).
- `scripts/renew-apm-token.sh` + cron guidance in [docs/deploy.md](docs/deploy.md): the
  APM fetch token is periodic (768h) and previously expired silently after 32 days,
  breaking SSO injection with no visible error until login.

### Fixed
- `deploy.sh` re-runs no longer mint a new CA. `gen-certs.sh` reused an existing
  `certs/ca.{crt,key}` — the previous behavior silently invalidated every issued client cert
  and browser import on the "just re-run it" path. `WARDEN_REGEN_CA=1` rolls it deliberately.
- First-run `deploy.sh` failed at step 5: the openldap container chowns `certs/` when the
  stack comes up (between `gen-certs.sh` and the client-cert signing). The reclaim logic
  moved to `scripts/lib/certs.sh` and now runs before signing in `gen-test-users.sh` too.
- Removed the remaining hardcoded directory/site values: the seed and OpenBao LDIFs no
  longer bake in `dc=warden,dc=lab` (they are templated per `.env`, so changing `BASE_DN`
  works), and the bundled compose reads `WARDEN_DOMAIN`.
- Removed the remaining hardcoded site-specific values: `apm-build.sh` no longer falls
  back to a hardcoded VIP (`WARDEN_APM_VIP` is required), `import-browser-certs.sh` takes
  `WARDEN_VM` (required) + `WARDEN_REMOTE_DIR` (default `/opt/warden`), and the reference
  docs/runbooks use `<WARDEN_APM_VIP>`-style placeholders instead of one lab's addresses.
- The APM OpenBao-fetch iRule hardcoded one site's OpenBao address (`10.2.20.30`), so any
  deploy to a different host silently sent the credential rotate/fetch to the wrong OpenBao
  (symptom: websso `Could not find SSO password`, empty local audit log). The iRules now
  carry a `${WARDEN_HOST_IP}` placeholder and `apm-build.sh` renders it from `.env` at
  upload time (`envsubst` restricted to that one variable so the iRule's own `$vars`
  survive).

## 2026-07-28
### Changed
- **Productized as a self-contained customer demo** under the name **Warden**. `.env` is now
  the single config surface (host, domain→BASE_DN, BIG-IP address(es), VIP, façades); added
  `./deploy.sh`
  one-command orchestration; the APM build supports a single BIG-IP or an HA pair via
  `WARDEN_BIGIP_B_*`; operator wrappers read `BIGIP_PASS` from `.env` or the environment.
- **Removed the browser-SSH gateway** — the demo focuses on the credential core + APM/TMUI; SSH is via
  the operator's own client with an issued credential.
- Docs reworked to be generic/customer-facing; superseded internal docs removed.

### Added
- Configurable credential model on the operator/issue path: `WARDEN_CRED_MODE`
  (`ephemeral`|`static`) behind a shared `scripts/lib/cred.sh` abstraction
  (`cred_issue`/`cred_revoke`); `issue-cred.sh`/`revoke-cred.sh` refactored onto it. Both
  modes verified end-to-end (issue → SSH login → revoke → denied)
  ([ADR 0006](docs/adr/0006-configurable-credential-model.md)). The APM injection path
  stays `static`; ephemeral-injection is a deferred step 2.

## 2026-07-27
### Added
- Documentation restructured to the repository documentation standard: `docs/` tree
  (architecture, 5 ADRs, install/deploy/upgrade, troubleshooting, runbooks, reference),
  rewritten README, CONTRIBUTING, this changelog.
- Kill switch un-stubbed: `scripts/revoke-all.sh` uses real 21.1 mechanisms
  (`sessiondump --delete` for APM, OpenBao rotate/lease-revoke) (DEVIATIONS 15).
- OpenBao productionized: raft persistence (`docker-compose.prod.yml`,
  `openbao/openbao-prod.hcl`), `scripts/openbao-init-unseal.sh`, boot-time
  `deploy/openbao-unseal.service` (AUTO-unseal). Persistence verified (DEVIATIONS 16,
  [ADR 0005](docs/adr/0005-openbao-persisted-auto-unseal.md)).

### Changed
- Portal Access delivery reworked to shadow façade VSs (192.0.2.5/.6); TMUI no longer
  exposed on the external VLAN; external self-IP `allow-service` locked to none
  (DEVIATIONS 12/14, [ADR 0003](docs/adr/0003-shadow-facade-portal-targets.md)).
- Authorization moved from the APM group filter to BIG-IP remote-role: any valid cert
  identity reaches the webtop; `bigip-admins` → admin, everyone else → read-only (guest)
  (DEVIATIONS 13, [ADR 0004](docs/adr/0004-authorization-on-bigip-remote-role.md)).
- TMUI session-pinning (`httpd.matchclient`, `auth-pam-validate-ip`) disabled on both units
  so proxied portal sessions survive (DEVIATIONS 11).

### Fixed
- Portal Access `reserved address` (errorcode=17) rejection — targets are now non-reserved
  façade IPs (DEVIATIONS 10).

## 2026-07-23
### Added
- Phase 2 full injection flow to the webtop: APM decision core, OpenBao iRule fetch, form
  SSO, Portal Access. GATE 2A passed.
- Phase 1 complete: OpenBao LDAP secrets engine, ephemeral leased users, `bigipa` on LDAPS
  auth. GATE 1A + GATE 1B passed.

## 2026-07-10
### Added
- Initial hybrid OSS Warden design and repo scaffold
  ([ADR 0001](docs/adr/0001-hybrid-oss-warden-design.md)).
