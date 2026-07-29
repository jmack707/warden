# Deploy — BIG-IP auth + APM front door

Configure the target BIG-IP(s) named in `.env`. Assumes [install.md](install.md) is done
and `validate-phase1.sh` passed. `./deploy.sh` runs these steps for you; this page is the
detail and the verification.

_Last validated: 2026-07 against TMOS 21.1.0 (single and In-Sync HA pair)._

## Preconditions
- APM provisioned and licensed on the BIG-IP (both units for an HA pair).
- `BIGIP_MGMT` / `BIGIP_USER` / `BIGIP_PASS` set in `.env` (demo) or `BIGIP_PASS` injected
  from your secret manager (production — leave it blank in `.env`).
- For HA, set `WARDEN_BIGIP_B_MGMT` and `WARDEN_BIGIP_B_TMUI`; leave empty for a single unit.
- `admin`/`root` stay local; this deployment never modifies them.

## Step 1 — BIG-IP auth (LDAPS system-auth)
```bash
BIGIP_PASS=<bigip-admin-pw> ./bigip/phase1-target-rest.sh   # or rely on .env
```
Installs the CA, `auth ldap system-auth` (LDAPS, CA-verified, bind `cn=bigip-bind`),
`remote-role warden_admins`, `remote-user default-role guest`, and switches the auth source
to LDAP.

Verify:
```bash
./scripts/gate1b-verify.sh
```
Expected: an issued credential authenticates to the target over REST/TMUI **and** SSH as
Administrator; a non-admin is denied; revoke ends auth.

## Step 2 — APM front door + credential injection
```bash
./bigip/run-apm-build.sh
```
Reads `BIGIP_PASS` from `.env` (or the environment), mints the scoped OpenBao token, and
runs the build. Idempotent (teardown-first). It creates: client-ssl (require client cert),
the APM AAA LDAP pool + server, the policy graph (Start → Cert Inspection → Extract CN →
LDAP Query → OpenBao Fetch → SSO → Resource Assign → Allow/Deny), form SSO, webtop, the
shadow façade VS(s) + Portal Access resource(s), and the test VIP `<WARDEN_APM_VIP>`. With
no HA peer set, only the local unit's façade/bookmark is built.

## Verification
```bash
cd clients
for u in alice.admin bob.user carol.expired; do
  curl -sk --cert $u.crt --key $u.key -o /dev/null -w "$u %{http_code}\n" -L "https://${WARDEN_APM_VIP}/"
done
```
Expected: `alice.admin` and `bob.user` reach the webtop (HTTP 200, effective URL contains
`/vdesk/webtop.eui`); `carol.expired` fails at the TLS handshake (curl exit 56). Then
confirm the role from the target's log:
```bash
grep pam_bigip_authz /var/log/secure | tail -2   # on the BIG-IP
```
Expected: `alice.admin ... role 0 (Administrator)`, `bob.user ... level=Guest`. The final
browser click-through is
[operations/runbooks/browser-verify.md](operations/runbooks/browser-verify.md).

## Keep the APM token alive
The scoped token the fetch iRule uses is periodic (`period=768h`) and dies if not renewed
within its period — the failure is silent (webtop loads, SSO injects an empty password).
Install a daily renewal on the warden host:
```bash
echo '0 4 * * * root /opt/warden/scripts/renew-apm-token.sh >> /var/log/warden-renew.log 2>&1' \
  | sudo tee /etc/cron.d/warden-renew-apm-token
```
`scripts/renew-apm-token.sh` reads the live token from the `warden_openbao_dg` datagroup
on `BIGIP_MGMT` and renews it against `BAO_ADDR`; it exits non-zero (and logs why) if
either step fails.
