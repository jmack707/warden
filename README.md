# warden — OSS replacement for F5 PUA (Dakota lab)

Certificate-authenticated privileged access to BIG-IP management, with a password the user
never sees and instant session termination — composed from OpenBao, OpenLDAP, Guacamole,
and BIG-IP APM, with no custom code in the credential path.

## What & why
F5 PUA gives operators time-boxed, audited privileged access without handing out standing
credentials. This rebuilds that from open-source parts:

- **OpenBao** mints/rotates the privileged password and is the broker.
- **OpenLDAP** is the single source of truth the target validates against.
- **BIG-IP APM** is the front door: client-cert auth, credential injection, reverse-proxied
  TMUI with form SSO, and session kill.
- **Guacamole** provides clientless SSH.

Design rationale is in [docs/adr/](docs/adr/); the full picture in
[docs/architecture.md](docs/architecture.md).

## Topology
- Runs on the **warden VM** (`10.2.20.30`, Dakota VLAN 73): OpenBao (`:8200`), OpenLDAP
  (`:636`), Guacamole (`:8080`).
- Targets the **Dakota BIG-IP pair** (`bigipa` 10.2.1.5, `bigipb` 10.2.1.6, TMOS 21.1.0).
- APM front door at VIP `https://10.2.20.50/`.

## Request flow (one line)
client cert → APM extracts CN → LDAP identity check → OpenBao rotates+fetches the password →
webtop → SSO into the target's TMUI → target authorizes by remote-role (admin vs read-only).

## Quickstart
```bash
cp .env.example .env            # fill in LAB_HOST_IP, BASE_DN, LDAP_ADMIN_PW, BIND_PW
scripts/gen-certs.sh
docker-compose up -d
scripts/configure-openbao.sh
scripts/validate-phase1.sh      # GATE 1A — must pass before touching the BIG-IP
```
Full first-time install: [docs/install.md](docs/install.md). BIG-IP deployment:
[docs/deploy.md](docs/deploy.md).

## Verification
```bash
scripts/validate-phase1.sh                   # credential core, no BIG-IP
docker ps --format '{{.Names}}: {{.Status}}' # all five containers Up
```

## Documentation
| Doc | For |
|---|---|
| [docs/architecture.md](docs/architecture.md) | components, data flow, trust boundaries |
| [docs/adr/](docs/adr/) | the decisions and why |
| [docs/install.md](docs/install.md) · [deploy.md](docs/deploy.md) · [upgrade.md](docs/upgrade.md) | standup, BIG-IP deploy, upgrade/rollback/teardown |
| [docs/operations/troubleshooting.md](docs/operations/troubleshooting.md) | symptom-first fixes |
| [docs/operations/runbooks/](docs/operations/runbooks/) | kill switch, OpenBao cutover, browser verify |
| [docs/reference/](docs/reference/) | configuration, CLI, API |
| [RUNBOOK.md](RUNBOOK.md) · [DEVIATIONS.md](DEVIATIONS.md) | original build plan · per-change record |

## Security notes
- Never commit `.env`, private keys, or issued passwords (all gitignored).
- `admin`/`root` on both BIG-IPs stay local — the recovery path.
- OpenBao runs raft-persisted with AUTO-unseal; the VM is the trust boundary
  ([ADR 0005](docs/adr/0005-openbao-persisted-auto-unseal.md)).

## Status
Phases 1–2 built and verified end-to-end (alice → admin, bob → read-only, carol → rejected).
The last open item is the operator browser click-through
([docs/operations/runbooks/browser-verify.md](docs/operations/runbooks/browser-verify.md)).
See [CHANGELOG.md](CHANGELOG.md).
