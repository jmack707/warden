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
curl -sk -u admin:<pw> -X DELETE https://<BIGIP_MGMT>/mgmt/tm/ltm/virtual/~Common~warden-apm-test-vs
curl -sk -u admin:<pw> -X DELETE https://<BIGIP_MGMT>/mgmt/tm/apm/profile/access/~Common~warden-apm
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
`./teardown.sh` removes what `deploy.sh` created, in reverse dependency order:

```bash
./teardown.sh --all --dry-run     # print exactly what would be removed, change nothing
./teardown.sh --all               # BIG-IP config + local stack (prompts to confirm)
./teardown.sh --bigip --yes       # BIG-IP only — leave the stack running
./teardown.sh --stack --yes       # stack only — leave the BIG-IP configured
./teardown.sh --all --purge --yes # also drop volumes, the CA, and issued client certs
```

Order is deliberate: the auth source flips back to **local** before the LDAP config is
deleted, so remote auth is never pointed at a half-removed configuration. `admin`/`root`
stay local throughout, so teardown cannot lock you out. `remote-user defaultRole` is
restored to `no-access` (Warden sets `guest`), so re-pointing auth later cannot silently
grant access.

What it deliberately leaves alone:
- the BIG-IP's local accounts, licence and provisioning;
- **an external directory** — Warden creates nothing in yours, so nothing is deleted there.
  It does remove the OpenBao static roles, which leaves those privileged accounts holding a
  password nobody knows: reset them in your directory afterwards
  ([directory.md](directory.md));
- without `--purge`: the Docker volumes and the CA, so `./deploy.sh` brings the same
  environment straight back. With `--purge` a re-deploy mints a **new CA**, so browser
  client certs must be re-imported.

Revoke live sessions first if operators are connected —
[operations/runbooks/revoke-session.md](operations/runbooks/revoke-session.md).

### Verification
```bash
./teardown.sh --all --dry-run     # after a teardown: every line should 404 / be absent
curl -sk -u admin:<pw> https://<BIGIP_MGMT>/mgmt/tm/auth/source | jq -r .type   # local
docker ps --format '{{.Names}}'                                                 # no openbao/openldap
```

### Verification
```bash
docker ps --filter name=openbao --format '{{.Names}}'   # expect: empty after down
```
