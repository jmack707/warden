# ADR 0005 — Persist OpenBao (raft) with AUTO-unseal custody

## Status
Accepted — 2026-07-27.

## Context
The PoC ran OpenBao in `-dev` mode: in-memory storage, fixed root token `root`,
auto-unsealed. State was lost on any container recreate, so every rebuild re-ran the
configure scripts. Unacceptable for anything beyond a demo.

## Decision
Switch to **raft integrated storage** (`docker-compose.prod.yml` +
`openbao/openbao-prod.hcl`), a real seal lifecycle (`operator init` → unseal, generated
root token), and an audit-file device. Key custody is **AUTO**: the unseal key + root token
live in a root-only file on the VM (`openbao/.openbao-keys.json`, 0600, gitignored), and a
systemd unit (`deploy/openbao-unseal.service`) unseals ~15 s after boot.

The listener stays HTTP on the internal VLAN. Locking OpenBao behind TLS on :8200 cascades
into the APM iRule sideband and the scoped-token flow, so it is deferred (see
[../upgrade.md](../upgrade.md)).

## Consequences
- State persists across container restart **and** recreate (verified: a restart preserved
  the static roles).
- Trust boundary: root on the VM can unseal OpenBao. Accepted for the lab; to move to MANUAL
  custody, `systemctl disable --now openbao-unseal`, copy the keys off, delete the file.
- 2.x gotchas encoded in the config/scripts: `disable_mlock` is a fatal error (omit it); a
  fresh raft/log volume is root-owned but the image runs as uid 100 (auto-chowned by the
  init script); compose merges env, so `BAO_DEV_*` must be blanked, not omitted.
- Migration + rollback runbook: [../operations/runbooks/openbao-cutover.md](../operations/runbooks/openbao-cutover.md).
