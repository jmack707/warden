# Runbook — OpenBao dev → production cutover

Migrate OpenBao from `-dev` (in-memory) to raft-persisted with a real seal lifecycle.

_Last validated: 2026-07 against OpenBao 2.x. Cutover executed 2026-07-27 (AUTO-unseal)._

## When to use this
Once, to move past the PoC. After this, container recreate no longer wipes state. Context
and rationale: [ADR 0005](../../adr/0005-openbao-persisted-auto-unseal.md).

## Prerequisites
- A working dev-mode deployment ([../../install.md](../../install.md)): `openbao` and
  `openldap` are `Up` and `./scripts/validate-phase1.sh` is green. The LDAP secrets engine is
  rebuilt against the running directory, so OpenLDAP must stay up throughout.
- Run from the repo root on the Docker host, with `docker` and the Compose **v2 plugin** — the
  procedure layers `docker-compose.prod.yml` over `docker-compose.yml`, which the standalone
  v1 binary cannot do the same way. `python3` and `jq` are needed by the scripts involved.
- Root/sudo on that host: `openbao-init-unseal.sh` chowns the `warden_openbaodata` /
  `warden_openbaologs` volumes to uid 100 / gid 1000 (a root-owned fresh volume makes the
  server crash-loop on `vault.db: permission denied`), and the auto-unseal step installs a
  unit into `/etc/systemd/system`.
- `.env` present and writable — `openbao-init-unseal.sh` rewrites `BAO_TOKEN` in place with
  the generated root token, and `bigip/run-apm-build.sh` needs `BIGIP_MGMT`/`BIGIP_USER` plus
  `BIGIP_PASS` (in `.env` or injected) with REST reachability to the target BIG-IP.
- A decision on key custody before you init: AUTO keeps `openbao/.openbao-keys.json` (0600,
  gitignored) on the VM so the stack self-unseals after a reboot; MANUAL means copying the
  keys off the VM and unsealing by hand after every restart. Either way the file is the only
  copy of the unseal keys.
- A maintenance window: expect roughly 5 minutes of downtime for the Warden flow, and accept
  that the dev-mode in-memory state is discarded (it is disposable by design).

## Procedure
Expect ~5 min downtime for the Warden flow.
```bash
cd <repo-root>
# 1. recreate openbao with the persisted prod config (dev in-memory state is disposable)
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d openbao
# 2. init + unseal; writes .env BAO_TOKEN, chowns the raft/log volumes
./scripts/openbao-init-unseal.sh
# 3. rebuild the secrets engine / roles / policies on the fresh store
./scripts/configure-openbao.sh
./scripts/configure-openbao-static.sh alice.admin bob.user
./scripts/configure-openbao-phase2.sh
# 4. re-mint the scoped token + rebuild APM so the data-group matches
bash bigip/run-apm-build.sh
```

Wire boot-time auto-unseal (AUTO custody):
```bash
cp deploy/openbao-unseal.service /etc/systemd/system/openbao-unseal.service
systemctl daemon-reload && systemctl enable --now openbao-unseal.service
```

## Verification
```bash
docker exec -e BAO_ADDR=http://127.0.0.1:8200 openbao bao status -format=json \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("storage",d["storage_type"],"sealed",d["sealed"])'
```
Expected: `storage raft sealed False`. Then prove persistence:
```bash
docker restart openbao && sleep 5 && ./scripts/openbao-init-unseal.sh
docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN=$(grep ^BAO_TOKEN .env|cut -d= -f2) \
  openbao bao list ldap/static-role
```
Expected: the container auto-unseals and the static roles (`alice.admin`, `bob.user`) are
still present — dev mode would have lost them. Finish with the full matrix in
[../../deploy.md](../../deploy.md#verification).

## Rollback
```bash
cd <repo-root>
docker compose up -d openbao        # base file only → dev mode
./scripts/configure-openbao.sh && ./scripts/configure-openbao-static.sh alice.admin bob.user
```
The raft volume is left intact for a retry. To switch AUTO → MANUAL custody:
`systemctl disable --now openbao-unseal`, copy `openbao/.openbao-keys.json` off the VM,
then delete it.

## Escalation
If init fails or the container crash-loops, see
[../troubleshooting.md](../troubleshooting.md#openbao-crash-loops); escalate to the lab
operator before deleting the raft volume (that is irreversible).
