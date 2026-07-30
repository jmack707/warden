# CLI reference — entry-point scripts

Every runnable script, its arguments, and where it runs. All read `.env` from the repo
root. Scripts that touch the BIG-IP need `BIGIP_PASS` injected at runtime (never from
`.env`).

_Last validated: 2026-07._

## Overview
Two top-level commands do everything; the rest are the individual steps they call, useful on
their own when you are building by hand ([manual-build.md](../manual-build.md)) or fixing one
layer.

| Command | Purpose |
|---|---|
| `./deploy.sh [--stack\|--bigip\|--all]` | Stand up the demo. Default `--all`; `--stack` skips the BIG-IP entirely (and stops requiring `BIGIP_*`); `--bigip` configures a BIG-IP against a stack that is already up |
| `./teardown.sh [--stack\|--bigip\|--all] [--purge] [--dry-run] [--yes]` | Remove what `deploy.sh` created, in reverse dependency order. `--dry-run` prints and changes nothing; `--purge` also drops volumes, the CA and issued certificates; `--yes` skips the confirmation prompt |

Both are idempotent and safe to re-run. Every script reads `.env` from the repo root, and
those that touch the BIG-IP accept `BIGIP_PASS` injected from the environment so the admin
secret need not be stored on disk. Exit codes follow the shell convention: `0` success,
non-zero failure, and `2` specifically means bad invocation (unknown flag, missing argument).

## Phase 1 — credential core (run on the VM)
| Script | Args | Purpose |
|---|---|---|
| `scripts/gen-certs.sh` | — | Generate the lab CA + LDAPS server cert (SAN must include `WARDEN_HOST_IP`) |
| `scripts/gen-test-users.sh` | `<base> <mode>` | Seed the alice/bob/carol identity entries, enable the memberof/refint overlay, and issue their client certs. The admin group is seeded separately, after the privileged accounts exist (`ldap/admin-group.ldif`) |
| `scripts/configure-openbao.sh` | — | Configure the OpenBao LDAP secrets engine + ephemeral role + audit device |
| `scripts/issue-cred.sh` | `[principal]` | Issue a credential per `WARDEN_CRED_MODE` (STDOUT only). `static` mode needs the principal (CN); `ephemeral` ignores it. Prints `{mode,username,password,handle,ttl}` |
| `scripts/revoke-cred.sh` | `<handle>` | Revoke by the handle from `issue-cred.sh`: a lease id → delete the ephemeral account; a CN → rotate the static password |
| `scripts/lib/authz.sh` | _(sourced)_ | Answers "will the BIG-IP grant Administrator to anyone?" — probes the directory as the BIG-IP's read-only bind over a default search, and flags a hand-set `WARDEN_ADMIN_ROLE_ATTRIBUTE` that bypasses the admin group. Used by `deploy.sh` (bundled) and `preflight-directory.sh` (external). Not run directly |
| `scripts/lib/cred.sh` | _(sourced)_ | Shared credential abstraction: `cred_issue`/`cred_revoke` over both models (ADR 0006). Not run directly |
| `scripts/validate-phase1.sh` | — | GATE 1A — end-to-end local validation, no BIG-IP |
| `scripts/gen-client-certs.sh` | `<CN> [CN ...]` | Issue Warden-CA client certs + `.p12` bundles for arbitrary principals. Used in external-directory mode, where Warden seeds no users. Writes nothing to the directory |
| `scripts/preflight-directory.sh` | — | Read-only validation of an EXTERNAL directory before the BIG-IP is touched: LDAPS chain, both binds, admin group, subtrees, and that the role attribute is returned by a default search. Exit `0` = safe to deploy |

## Phase 2 — injection, static roles, tokens (run on the VM)
| Script | Args | Purpose |
|---|---|---|
| `scripts/configure-openbao-static.sh` | `[CN ...]` (default `alice.admin`) | Create/rotate OpenBao static roles for privileged access accounts |
| `scripts/configure-openbao-phase2.sh` | — | Create the scoped `warden-apm-read` policy + mint the APM token |
| `scripts/mint-apm-token.sh` | — | Mint a fresh scoped OpenBao token (used by the APM build) |
| `scripts/renew-apm-token.sh` | — | Renew the periodic token the fetch iRule uses, reading the live value from the BIG-IP datagroup. Run daily from cron — the token dies silently otherwise ([deploy.md](../deploy.md#keep-the-apm-token-alive)) |
| `scripts/import-browser-certs.sh` | — | Operator helper: import test client certs into a browser (p12 pass `warden`) |

## Lifecycle
| Script | Args | Purpose |
|---|---|---|
| `deploy.sh` | `[--stack\|--bigip\|--all]`, `--help` | Orchestrates everything below in order; see Overview. In bundled mode it also verifies, before finishing, that the admin group will actually grant Administrator (`scripts/lib/authz.sh`) |
| `teardown.sh` | `[--stack\|--bigip\|--all] [--purge] [--dry-run] [--yes]`, `--help` | Reverses it. Flips `auth source` back to local BEFORE deleting the LDAP config, restores `remote-user` to `no-access`, and never modifies an external directory |

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
