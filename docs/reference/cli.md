# CLI reference — entry-point scripts

Every runnable script, its arguments, and where it runs. All read `.env` from the repo
root. Scripts that touch the BIG-IP need `BIGIP_PASS` injected at runtime (never from
`.env`).

_Last validated: 2026-07._

## Phase 1 — credential core (run on the VM)
| Script | Args | Purpose |
|---|---|---|
| `scripts/gen-certs.sh` | — | Generate the lab CA + LDAPS server cert (SAN must include `LAB_HOST_IP`) |
| `scripts/gen-test-users.sh` | `<base> <mode>` | Seed the alice/bob/carol test principals + memberOf overlay |
| `scripts/configure-openbao.sh` | — | Configure the OpenBao LDAP secrets engine + ephemeral role + audit device |
| `scripts/issue-cred.sh` | — | Issue an ephemeral BIG-IP admin credential (STDOUT only) |
| `scripts/revoke-cred.sh` | `<lease_id>` | Revoke a lease; deletes the ephemeral LDAP entry immediately |
| `scripts/validate-phase1.sh` | — | GATE 1A — end-to-end local validation, no BIG-IP |

## Phase 2 — injection, static roles, tokens (run on the VM)
| Script | Args | Purpose |
|---|---|---|
| `scripts/configure-openbao-static.sh` | `[CN ...]` (default `alice.admin`) | Create/rotate OpenBao static roles for privileged access accounts |
| `scripts/configure-openbao-phase2.sh` | — | Create the scoped `pua-apm-read` policy + mint the APM token |
| `scripts/mint-apm-token.sh` | — | Mint a fresh scoped OpenBao token (used by the APM build) |
| `scripts/configure-guacamole.sh` | — | Rotate guacadmin pw + create the SSH connection |
| `scripts/import-browser-certs.sh` | — | Operator helper: import test client certs into a browser (p12 pass `pua`) |

## Session termination
| Script | Args | Purpose |
|---|---|---|
| `scripts/revoke-all.sh` | `--cn <CN> [--lease <id>] [--apm-key <key>] [--guac-id <uuid>]` (or legacy positional `<lease_id> [apm_key] [guac_id]`) | Kill switch: OpenBao rotate/revoke + APM `sessiondump --delete` + Guac PATCH-remove |
| `bigip/run-revoke.sh` | same as `revoke-all.sh` | **Run on Nora.** Fetches `BIGIP_PASS` via AppRole, pipes it over ssh stdin, runs `revoke-all.sh` on the VM |

## OpenBao production lifecycle
| Script | Args | Purpose |
|---|---|---|
| `scripts/openbao-init-unseal.sh` | env `SHARES`/`THRESHOLD` (default 1/1) | Idempotent init + unseal; chowns raft/log volumes; writes `.env` `BAO_TOKEN` on first init |

## BIG-IP builds
| Script | Args | Purpose |
|---|---|---|
| `bigip/phase1-target-rest.sh` | env `BIGIP_PASS`, `BIND_PW` | Phase 1 target auth: CA, LDAPS system-auth, remote-role, auth-source flip |
| `bigip/phase2-apm-dakota-rest.sh` | env `BIGIP_PASS`, `BIND_PW`, `APM_TOKEN`; opt `APM_TARGET_TMUI`, `APM_SHADOW_A/B`, `APM_TEST_VIP` | Build the full APM policy, façades, portal, webtop, test VIP (idempotent, teardown-first) |
| `bigip/run-dakota-apm-build.sh` | passes through to the build | **Run on Nora.** Fetches `BIGIP_PASS` via AppRole, mints the scoped token, runs the APM build |
| `scripts/gate1b-verify.sh` | env `BIGIP_PASS` (optional) | GATE 1B — verify ephemeral auth to the target over REST/TMUI + SSH |
