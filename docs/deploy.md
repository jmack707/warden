# Deploy — BIG-IP auth + APM front door (Phases 1.7–2)

Environment-specific deployment against the Dakota BIG-IP pair (`bigipa` 10.2.1.5,
`bigipb` 10.2.1.6). Assumes [install.md](install.md) is done and GATE 1A passed.

_Last validated: 2026-07 against TMOS 21.1.0 (bigipa/bigipb HA pair, In-Sync)._

## Preconditions
- APM is provisioned and licensed on **both** units (incl. the PUA endpoint license).
- The BIG-IP admin password is fetched at runtime via the lab OpenBao f5-onboard AppRole —
  it is **never** stored in `.env` (`BIGIP_PASS` there is empty by design).
- `admin`/`root` stay local on both units; this deployment never modifies them.

## Step 1 — Phase 1 target auth (LDAPS system-auth)
```bash
BIGIP_PASS=<bigipa-admin-pw> bigip/phase1-target-rest.sh
```
This installs the CA, `auth ldap system-auth` (LDAPS, CA-verified, bind `cn=bigip-bind`),
`remote-role pua_admins`, and flips the auth source to LDAP. The final auth-source flip may
be blocked by the harness auto-mode guard — if so, an operator runs the printed command.

Verify (GATE 1B):
```bash
scripts/gate1b-verify.sh
```
Expected: an ephemeral user authenticates to the target over REST/TMUI **and** SSH as
Administrator; a non-admin is denied (401); revoke ends auth. Green = proceed.

## Step 2 — APM decision core + full injection flow
Run the operator wrapper on Nora (fetches the admin pw via AppRole, mints the scoped
OpenBao token, then builds against bigipa):
```bash
bash bigip/run-dakota-apm-build.sh
```
The build is idempotent (teardown-first) and re-runnable. It creates: client-ssl (require
client cert), the APM AAA LDAP pool + server, the policy graph
(Start → Cert Inspection → Extract CN → LDAP Query → OpenBao Fetch → SSO → Resource Assign
→ Allow/Deny), form SSO, webtop, both shadow façade VSs + Portal Access resources, and the
test VIP `10.2.20.50`.

> The build runs from **Nora's** `/root/pua-oss` mirror, not the VM repo. Commit on the VM
> and `git pull` on Nora before building, or your script edits will not take effect.

## Step 3 — Guacamole connection (clientless SSH path)
```bash
scripts/configure-guacamole.sh
```

## Verification
```bash
cd /root/pua-oss/certs/clients
for u in alice.admin bob.user carol.expired; do
  curl -sk --cert $u.crt --key $u.key -o /dev/null -w "$u %{http_code}\n" -L https://10.2.20.50/
done
```
Expected: `alice.admin` and `bob.user` reach the webtop (HTTP 200, effective URL contains
`/vdesk/webtop.eui`); `carol.expired` fails at the TLS handshake (curl exit 56). Then
confirm the role from the target:
```bash
# on the target: grep the last authz decision
grep pam_bigip_authz /var/log/secure | tail -2
```
Expected: `alice.admin ... role 0 (Administrator)`, `bob.user ... level=Guest`.
The final browser click-through is [operations/runbooks/browser-verify.md](operations/runbooks/browser-verify.md).
