# Changelog

Notable changes to the warden lab build. Dates are absolute. Per-change lab specifics and
gotchas are in [DEVIATIONS.md](DEVIATIONS.md); decisions in [docs/adr/](docs/adr/).

## 2026-07-28
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
- Kill switch un-stubbed: `scripts/revoke-all.sh` now uses real 21.1 mechanisms
  (`sessiondump --delete` for APM, Guac 1.6 PATCH-remove, OpenBao rotate/lease-revoke) with
  the Nora wrapper `bigip/run-revoke.sh` (DEVIATIONS 15).
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
  auth, Guacamole SSH connection. GATE 1A + GATE 1B passed.

## 2026-07-10
### Added
- Initial hybrid OSS Warden design and repo scaffold
  ([ADR 0001](docs/adr/0001-hybrid-oss-warden-design.md)).
