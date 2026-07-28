# Runbook — OpenBao dev → production cutover

Migrate OpenBao from `-dev` (in-memory) to raft-persisted with a real seal lifecycle.

_Last validated: 2026-07 against OpenBao 2.x. Cutover executed 2026-07-27 (AUTO-unseal)._

## When to run
Once, to move past the PoC. After this, container recreate no longer wipes state. Context
and rationale: [ADR 0005](../../adr/0005-openbao-persisted-auto-unseal.md).

## Procedure (~5 min downtime for the Warden flow)
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
