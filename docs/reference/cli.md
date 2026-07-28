# CLI reference — entry-point scripts

Every runnable script, its arguments, and where it runs. All read `.env` from the repo
root. Scripts that touch the BIG-IP need `BIGIP_PASS` injected at runtime (never from
`.env`).

_Last validated: 2026-07._

## Phase 1 — credential core (run on the VM)
| Script | Args | Purpose |
|---|---|---|
| `scripts/gen-certs.sh` | — | Generate the lab CA + LDAPS server cert (SAN must include `WARDEN_HOST_IP`) |
| `scripts/gen-test-users.sh` | `<base> <mode>` | Seed the alice/bob/carol test principals + memberOf overlay |
| `scripts/configure-openbao.sh` | — | Configure the OpenBao LDAP secrets engine + ephemeral role + audit device |
| `scripts/issue-cred.sh` | `[principal]` | Issue a credential per `WARDEN_CRED_MODE` (STDOUT only). `static` mode needs the principal (CN); `ephemeral` ignores it. Prints `{mode,username,password,handle,ttl}` |
| `scripts/revoke-cred.sh` | `<handle>` | Revoke by the handle from `issue-cred.sh`: a lease id → delete the ephemeral account; a CN → rotate the static password |
| `scripts/lib/cred.sh` | _(sourced)_ | Shared credential abstraction: `cred_issue`/`cred_revoke` over both models (ADR 0006). Not run directly |
| `scripts/validate-phase1.sh` | — | GATE 1A — end-to-end local validation, no BIG-IP |

## Phase 2 — injection, static roles, tokens (run on the VM)
| Script | Args | Purpose |
|---|---|---|
| `scripts/configure-openbao-static.sh` | `[CN ...]` (default `alice.admin`) | Create/rotate OpenBao static roles for privileged access accounts |
| `scripts/configure-openbao-phase2.sh` | — | Create the scoped `warden-apm-read` policy + mint the APM token |
| `scripts/mint-apm-token.sh` | — | Mint a fresh scoped OpenBao token (used by the APM build) |
| `scripts/import-browser-certs.sh` | — | Operator helper: import test client certs into a browser (p12 pass `warden`) |

## Session termination
| Script | Args | Purpose |
|---|---|---|
| `scripts/revoke-all.sh` | `--cn <CN> [--lease <id>] [--apm-key <key>]` | Kill switch: OpenBao rotate/revoke + APM `sessiondump --delete` |

## OpenBao production lifecycle
| Script | Args | Purpose |
|---|---|---|
| `scripts/openbao-init-unseal.sh` | env `SHARES`/`THRESHOLD` (default 1/1) | Idempotent init + unseal; chowns raft/log volumes; writes `.env` `BAO_TOKEN` on first init |

## BIG-IP builds
| Script | Args | Purpose |
|---|---|---|
| `bigip/phase1-target-rest.sh` | env `BIGIP_PASS`, `BIND_PW` | Phase 1 target auth: CA, LDAPS system-auth, remote-role, auth-source flip |
| `bigip/apm-build.sh` | env `BIGIP_PASS`, `BIND_PW`, `APM_TOKEN`; opt `WARDEN_BIGIP_B_TMUI`, `WARDEN_SHADOW_A/B`, `WARDEN_APM_VIP` | Build the full APM policy, façades, portal, webtop, test VIP (idempotent, teardown-first) |
| `bigip/run-apm-build.sh` | passes through to the build | Reads `BIGIP_PASS` from `.env` (or env), mints the scoped token, runs the APM build |
| `scripts/gate1b-verify.sh` | env `BIGIP_PASS` (optional) | GATE 1B — verify ephemeral auth to the target over REST/TMUI + SSH |
