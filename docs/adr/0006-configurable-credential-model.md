# ADR 0006 — Configurable credential model (ephemeral vs static)

## Status
Accepted — 2026-07-28.

## Context
The repo delivers credentials two ways: **leased ephemeral** (OpenBao mints a throwaway
account, `ldap/creds/warden-admin`, that is deleted at TTL) and **rotated static** (OpenBao
rotates the password of a standing account, `ldap/static-role/<CN>`). Originally the model
was implied by the path — Phase 1 was always ephemeral, the APM injection flow always
static — so choosing one meant editing scripts. We want the model to be a setting.

## Decision
Introduce `WARDEN_CRED_MODE` (`ephemeral` | `static`, default `ephemeral`) and route the
operator/issue path through a single abstraction, `scripts/lib/cred.sh`:
- `cred_issue [principal]` → uniform JSON `{mode, username, password, handle, ttl}`.
  - ephemeral: mint `ldap/creds/$WARDEN_EPHEMERAL_ROLE`; username is random; `handle` = lease id.
  - static: rotate `ldap/rotate-role/<principal>` then read `ldap/static-cred/<principal>`;
    username = the principal (CN); `handle` = the principal. Requires the static role to
    exist (`configure-openbao-static.sh <CN>`).
- `cred_revoke <handle>` → the handle is self-describing: a lease id (contains `/`) is
  lease-revoked (account deleted); a bare CN is rotated (old password invalidated).

`issue-cred.sh` and `revoke-cred.sh` now just source the library. `.env` sets the default;
an explicit inline `WARDEN_CRED_MODE=…` wins over it (preserved across the `.env` source, same
guard used for `BIGIP_PASS`).

Scope: **this ADR covers the operator/issue path (step 1).** The global toggle is
deployment-wide; per-principal selection is a later extension. Teaching the APM injection
iRule to honor `ephemeral` (which changes the injected login name to a random account — the
target no longer sees the identity CN) is a separate, larger step and is **not** included
here; the APM path remains `static`.

## Consequences
- Operators pick the model by setting one variable; both modes are verified end-to-end
  (issue → SSH login → revoke → denied).
- `revoke-all.sh` already handled both models; it stays compatible (handles are the same
  shape the helper emits).
- Because the handle encodes the model, revoke does not need to know the mode — a mixed
  environment (some ephemeral, some static handles) revokes correctly.
- `static` mode requires the principal's static role to pre-exist; `ephemeral` needs none.
