# Changelog

Notable changes to Warden. Dates are absolute. Engineering notes are in
[DEVIATIONS.md](DEVIATIONS.md); decisions in [docs/adr/](docs/adr/).

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
