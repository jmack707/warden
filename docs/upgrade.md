# Upgrade, rollback & teardown

_Last validated: 2026-07 against TMOS 21.1.0, OpenBao 2.x._

## Supported paths
There is no in-place version upgrade to perform: Warden is configuration, so "upgrading" means
re-applying it from a newer revision of this repo. Three paths are supported:

| From | To | How |
|---|---|---|
| An older revision of this repo | `main` | `git pull`, then re-run `./deploy.sh` (or just `--bigip` / `--stack`) |
| OpenBao dev mode | raft-persisted with auto-unseal | [the cutover runbook](operations/runbooks/openbao-cutover.md) |
| Bundled OpenLDAP | your own AD/LDAP | set `WARDEN_DIRECTORY_MODE=external`, run `scripts/preflight-directory.sh`, then re-deploy ([directory.md](directory.md)) |

Downgrading is the same operation against an older revision, with the rollback caveat below.

## Pre-upgrade checks
Confirm the current state is healthy before changing it, so a failure afterwards is
unambiguous:

```bash
./scripts/validate-phase1.sh                  # credential core still green
docker compose --profile bundled ps           # openbao + openldap Up
./teardown.sh --all --dry-run                 # inventory of what is currently deployed
git log --oneline -1                          # the revision you are coming from
```

Note the CA fingerprint if operators hold browser certificates — a re-deploy reuses an
existing CA, but confirming it lets you rule that out later:

```bash
openssl x509 -in certs/ca.crt -noout -fingerprint -sha256
```

## Procedure
The APM build is idempotent and teardown-first, so an upgrade is a re-run:

```bash
git pull                          # take the newer revision
./deploy.sh                       # or --stack / --bigip for one half
```

## Verification
```bash
./scripts/validate-phase1.sh      # credential core, no BIG-IP
cd clients && for u in alice.admin bob.user carol.expired; do
  curl -sk --cert $u.crt --key $u.key -o /dev/null -w "$u %{http_code}\n" -L "https://${WARDEN_APM_VIP}/"
done
```

Expected, unchanged from [deploy.md](deploy.md#verification): `alice.admin` and `bob.user`
reach the webtop (`200`), `carol.expired` fails at the TLS handshake. If the CA fingerprint
changed, browser certificates must be re-imported.

## Rollback
Re-running the build from the previous committed revision restores the prior policy, because
it tears the mutable graph down first:

```bash
git checkout <previous-revision>
./deploy.sh --bigip
```

To back the BIG-IP out entirely instead:

```bash
./teardown.sh --bigip --yes
```

## OpenBao dev → production cutover
See the dedicated runbook:
[operations/runbooks/openbao-cutover.md](operations/runbooks/openbao-cutover.md). It covers
the raft migration, init/unseal, reconfigure, and rollback to dev mode.

## Pending: OpenBao TLS on :8200 (not yet done)
The OpenBao listener is HTTP on the internal VLAN. Enabling TLS cascades into:
- the APM iRule sideband (`bigip/apm-openbao-fetch-static.irule`) — HTTP → HTTPS connect;
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
