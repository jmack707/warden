# OpenBao — dev → production (persisted, sealed) migration

The PoC ran OpenBao in `-dev` mode: in-memory storage, fixed root token `root`, auto-unsealed,
HTTP. State was lost on any container **recreate** (every rebuild re-ran the configure scripts).
Production swaps in **integrated raft storage** so state persists across restart *and* recreate,
and a real **seal lifecycle** (init → unseal, generated root token).

## What changes
| | dev (PoC) | prod |
|---|---|---|
| storage | in-memory | raft, volume `openbaodata` (persists) |
| root token | `root` (fixed) | generated at `operator init`, stored in `.env` |
| seal | auto-unsealed | boots **sealed**, unseal via `scripts/openbao-init-unseal.sh` |
| listener | HTTP :8200 | HTTP :8200 (unchanged — TLS is a tracked follow-on) |
| audit | declarative file device | same |

Listener stays HTTP on the internal VLAN so the APM iRule sideband, `mint-apm-token.sh`, and
the `bao()` helpers keep working unchanged. Locking OpenBao behind TLS cascades into the iRule
and scoped-token flow — deliberately deferred.

## Cutover (operator, ~5 min downtime for the PUA flow)
```
cd /root/pua-oss
docker-compose down openbao                        # drop the dev container (in-mem state is disposable)
docker-compose -f docker-compose.yml -f docker-compose.prod.yml up -d openbao
./scripts/openbao-init-unseal.sh                   # first run: init + unseal + write .env BAO_TOKEN
# rebuild the secrets engine/roles/policies on the fresh persisted store:
./scripts/configure-openbao.sh
./scripts/configure-openbao-static.sh alice.admin bob.user
./scripts/configure-openbao-phase2.sh
# re-mint the APM scoped token (its value changed) and rebuild APM so the datagroup matches:
bash bigip/run-dakota-apm-build.sh
./scripts/validate-phase1.sh                        # green = done
```
After this, a container **recreate no longer wipes state** — you only re-run
`openbao-init-unseal.sh` (it just unseals; it won't re-init an initialized store).

## Key custody — PICK ONE (this is the security decision)
`operator init` prints unseal key(s) + the root token; the script saves them to
`openbao/.openbao-keys.json` (0600, gitignored).
- **AUTO-unseal (lab-pragmatic):** leave the key file on the VM and run
  `openbao-init-unseal.sh` at boot (add a compose healthcheck or a systemd unit) so the
  stack self-recovers after a reboot. Trade-off: an attacker with root on the VM can unseal.
  Acceptable when the VM itself is the trust boundary.
- **MANUAL unseal (most secure):** copy the keys OFF the VM, `rm openbao/.openbao-keys.json`,
  and unseal by hand after each restart. No unattended boot.
- Raise `SHARES`/`THRESHOLD` (e.g. `SHARES=5 THRESHOLD=3 ./scripts/openbao-init-unseal.sh`)
  to split custody across people. Default is 1/1 for single-operator auto-unseal.

## Rollback
`docker-compose up -d openbao` (base file only) returns to dev mode; re-run the configure
scripts. The raft volume is left intact for a retry.
