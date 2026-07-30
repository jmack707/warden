# Warden — OSS privileged access for BIG-IP

A self-contained demo of certificate-authenticated privileged access to BIG-IP management,
with a password the operator never sees and instant session termination — composed from
OpenBao, OpenLDAP, and BIG-IP APM, with no custom code in the credential path.

## What this is
Warden gives operators time-boxed, audited access to BIG-IP management without handing out
standing credentials — built entirely from open-source parts:

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

Already have a directory? Set `WARDEN_DIRECTORY_MODE=external` and Warden uses **your AD or
LDAP** instead, creating nothing in it — you define which group grants BIG-IP admin
(`WARDEN_ADMIN_GROUP_DN`). See [docs/directory.md](docs/directory.md).

## Topology
The operator never reaches the BIG-IP's management interface directly, and never holds a
password. The front door is an APM virtual server; the broker and directory sit on a Docker
host the BIG-IP can reach on `:636` (LDAPS) and `:8200` (OpenBao).

```text
  operator                    BIG-IP (APM)                  Docker host
  ────────                    ────────────                  ───────────
  browser  ──client cert──▶  <WARDEN_APM_VIP>:443
   (.p12)                          │
                                   ├── identity lookup ──▶  OpenLDAP  :389/:636
                                   │   (CN from the cert)
                                   ├── fetch credential ─▶  OpenBao   :8200
                                   │   (scoped token, iRule sideband)
                                   ▼
                             webtop + form SSO
                                   │
                                   ▼
                        target TMUI (reverse-proxied)
                                   │
                          binds the injected credential
                                   ▼
                             LDAPS ──▶ OpenLDAP, then remote-role
                             decides admin vs read-only
```

In one line: client cert → APM extracts CN → LDAP identity check → OpenBao rotates and
returns the password → webtop → SSO into the target's TMUI → the BIG-IP authorizes by
remote-role. The operator sees a session, never a secret.

## Components
| Component | Runs where | Job |
|---|---|---|
| **OpenBao** | Docker, this host | Owns and rotates the privileged credential; issues it only to a narrowly-scoped token. The broker |
| **OpenLDAP** | Docker, this host | The directory the BIG-IP validates against. Optional — point Warden at your own AD/LDAP instead ([docs/directory.md](docs/directory.md)) |
| **BIG-IP APM** | your BIG-IP | The front door: client-certificate auth, identity lookup, credential injection, reverse-proxied TMUI with form SSO, session kill |
| **BIG-IP LTM + `remote-role`** | your BIG-IP | Authorization. Everyone who authenticates gets read-only; only the admin group is elevated |

Nothing in the credential path is custom code — it is configuration of off-the-shelf parts.

## Quickstart
```bash
cp .env.example .env      # fill in the <angle-bracket> values: host IP, domain, BIG-IP address, passwords
./deploy.sh               # stands up the stack, configures OpenBao/LDAP, builds the APM front door
```
`deploy.sh` is idempotent; re-run it after editing `.env`. Details:
[docs/install.md](docs/install.md) (the OSS stack) and [docs/deploy.md](docs/deploy.md)
(the BIG-IP).

## Verification
```bash
./scripts/validate-phase1.sh                 # credential core, no BIG-IP
docker ps --format '{{.Names}}: {{.Status}}' # openbao + openldap Up
```
Then browse `https://<WARDEN_APM_VIP>/` with a client cert —
[docs/operations/runbooks/browser-verify.md](docs/operations/runbooks/browser-verify.md).
Expected: `alice.admin` → admin webtop, `bob.user` → read-only, `carol.expired` → rejected.

## Teardown
```bash
./teardown.sh --all --dry-run     # show what would be removed
./teardown.sh --all               # remove the BIG-IP config + local stack
```
Auth source returns to local first (admin/root are never affected), and an external
directory is never modified — [docs/upgrade.md](docs/upgrade.md#teardown).

## Configuration
Everything is driven by `.env` — see [.env.example](.env.example) and the full reference in
[docs/reference/configuration.md](docs/reference/configuration.md). The credential model is
selectable (`WARDEN_CRED_MODE`): `static` (inject a rotated password the user never sees) or
`ephemeral` (a throwaway leased account) — [ADR 0006](docs/adr/0006-configurable-credential-model.md).

## Documentation
| Doc | For |
|---|---|
| [docs/architecture.md](docs/architecture.md) | components, data flow, trust boundaries |
| [docs/directory.md](docs/directory.md) | bring your own AD/LDAP; defining the BIG-IP admin group |
| [docs/manual-build.md](docs/manual-build.md) | build it a layer at a time, with the why behind each |
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

## License
[Apache License 2.0](LICENSE). Warden composes OpenBao, OpenLDAP and BIG-IP APM; those carry
their own licenses, and a licensed BIG-IP with APM provisioned is your responsibility to
supply.

See [CHANGELOG.md](CHANGELOG.md) for history, [CONTRIBUTING.md](CONTRIBUTING.md) to
contribute, and [SECURITY.md](SECURITY.md) to report a vulnerability.
