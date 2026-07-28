# Warden — OSS privileged access for BIG-IP

A self-contained demo of certificate-authenticated privileged access to BIG-IP management,
with a password the operator never sees and instant session termination — composed from
OpenBao, OpenLDAP, and BIG-IP APM, with no custom code in the credential path.

## What & why
F5 PUA (Privileged User Access) gives operators time-boxed, audited access without handing
out standing credentials. Warden rebuilds that idea from open-source parts:

- **OpenBao** mints/rotates the privileged credential and is the broker.
- **OpenLDAP** is the single source of truth the BIG-IP validates against.
- **BIG-IP APM** is the front door: client-cert auth, credential injection, reverse-proxied
  TMUI with form SSO, and session kill.

Design rationale is in [docs/adr/](docs/adr/); the full picture in
[docs/architecture.md](docs/architecture.md).

## What you provide
Warden runs its own OpenBao + OpenLDAP in Docker. You bring **one BIG-IP** (or an HA pair)
with APM provisioned and licensed, and put its address in `.env`. Everything else — the CA,
certs, directory, OpenBao roles, and APM policy — the demo builds.

## Request flow (one line)
client cert → APM extracts CN → LDAP identity check → OpenBao rotates + fetches the password
→ webtop → SSO into the target's TMUI → the BIG-IP authorizes by remote-role (admin vs
read-only).

## Quickstart
```bash
cp .env.example .env      # fill in the <angle-bracket> values: host IP, domain, BIG-IP address, passwords
./deploy.sh               # stands up the stack, configures OpenBao/LDAP, builds the APM front door
```
`deploy.sh` is idempotent; re-run it after editing `.env`. Details:
[docs/install.md](docs/install.md) (the OSS stack) and [docs/deploy.md](docs/deploy.md)
(the BIG-IP).

## Verify
```bash
./scripts/validate-phase1.sh                 # credential core, no BIG-IP
docker ps --format '{{.Names}}: {{.Status}}' # openbao + openldap Up
```
Then browse `https://<WARDEN_APM_VIP>/` with a client cert —
[docs/operations/runbooks/browser-verify.md](docs/operations/runbooks/browser-verify.md).
Expected: `alice.admin` → admin webtop, `bob.user` → read-only, `carol.expired` → rejected.

## Configuration
Everything is driven by `.env` — see [.env.example](.env.example) and the full reference in
[docs/reference/configuration.md](docs/reference/configuration.md). The credential model is
selectable (`WARDEN_CRED_MODE`): `static` (inject a rotated password the user never sees) or
`ephemeral` (a throwaway leased account) — [ADR 0006](docs/adr/0006-configurable-credential-model.md).

## Documentation
| Doc | For |
|---|---|
| [docs/architecture.md](docs/architecture.md) | components, data flow, trust boundaries |
| [docs/adr/](docs/adr/) | the decisions and why |
| [docs/install.md](docs/install.md) · [deploy.md](docs/deploy.md) · [upgrade.md](docs/upgrade.md) | stack standup, BIG-IP deploy, upgrade/rollback/teardown |
| [docs/operations/troubleshooting.md](docs/operations/troubleshooting.md) | symptom-first fixes |
| [docs/operations/runbooks/](docs/operations/runbooks/) | kill switch, OpenBao cutover, browser verify |
| [docs/reference/](docs/reference/) | configuration, CLI, API |

## Security notes
- Never commit `.env`, private keys, or issued passwords (all gitignored).
- `admin`/`root` on the BIG-IP stay local — the recovery path, never LDAP.
- For the demo, `BIGIP_PASS` sits in `.env`; in production inject it from a secret manager
  instead (the wrappers honor an injected value).
- OpenBao can run raft-persisted with auto-unseal
  ([ADR 0005](docs/adr/0005-openbao-persisted-auto-unseal.md)).

See [CHANGELOG.md](CHANGELOG.md) for history.
