# Upgrade, rollback & teardown

_Last validated: 2026-07 against TMOS 21.1.0, OpenBao 2.x._

## Rebuilding the APM policy
The APM build is idempotent and teardown-first, so an upgrade is a re-run:
```bash
# edit scripts, then re-run the build:

bash /root/warden/bigip/run-apm-build.sh
```
Verify with the matrix in [deploy.md](deploy.md#verification).

### Rollback
Re-running the build from the previous committed revision restores the prior policy (it
tears down the mutable graph first). To back out entirely, delete the test VS and access
profile:
```bash
# via iControl REST as admin:
curl -sk -u admin:<pw> -X DELETE https://10.2.1.5/mgmt/tm/ltm/virtual/~Common~warden-apm-test-vs
curl -sk -u admin:<pw> -X DELETE https://10.2.1.5/mgmt/tm/apm/profile/access/~Common~warden-apm
```

## OpenBao dev → production cutover
See the dedicated runbook:
[operations/runbooks/openbao-cutover.md](operations/runbooks/openbao-cutover.md). It covers
the raft migration, init/unseal, reconfigure, and rollback to dev mode.

## Pending: OpenBao TLS on :8200 (not yet done)
The OpenBao listener is HTTP on the internal VLAN. Enabling TLS cascades into:
- the APM iRule sideband (`bigip/apm-openbao-fetch-dakota.irule`) — HTTP → HTTPS connect;
- `scripts/mint-apm-token.sh` and every `bao()` helper (`BAO_ADDR` scheme);
- `.env` `BAO_ADDR`.
Do all of these together in one change, then re-run the APM build so the data-group token
path still resolves. Until then, the internal VLAN is the control.

## Teardown
```bash
cd /root/warden
docker compose -f docker-compose.yml -f docker-compose.prod.yml down   # stop stack
# to also drop persisted state (IRREVERSIBLE): add -v to remove the raft/ldap volumes
```
On the BIG-IP, revoke any live sessions first with
[operations/runbooks/revoke-session.md](operations/runbooks/revoke-session.md), then delete
the APM/LTM objects as in Rollback above. `admin`/`root` and the local auth source are left
intact.

### Verification
```bash
docker ps --filter name=openbao --format '{{.Names}}'   # expect: empty after down
```
