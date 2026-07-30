# Troubleshooting

Symptom-first. Find the row, jump to the section. Every failure here was hit during the
build; the detail lives in [../../DEVIATIONS.md](../../DEVIATIONS.md).

_Last validated: 2026-07 against TMOS 21.1.0, OpenBao 2.x._

## Symptom index
| Symptom | Likely cause | Section |
|---|---|---|
| Webtop loads, TMUI login does not submit, apm log `Could not find SSO password for user` | The OpenBao credential fetch failed — not SSO | [SSO password not found](#sso-password-not-found) |
| Everyone authenticates but lands read-only, no error anywhere | `remote-role` never matched the mapping attribute | [Everyone lands read-only](#everyone-lands-read-only) |
| `ldap_add: Server is unwilling to perform … no global superior knowledge` while seeding | Entry is outside the directory suffix — `BASE_DN` mismatch | [Seeding rejected by the directory](#seeding-rejected-by-the-directory) |
| OpenBao rotate or read fails with `LDAP Result Code 32 "No Such Object"` | The privileged account the static role names does not exist | [Static role points at a missing account](#static-role-points-at-a-missing-account) |
| Webtop bookmark → `my.acl.php3?errorcode=17`, apm log `01490585 ... reserved address` | Portal target is a cluster-reserved address | [Reserved-address rejection](#reserved-address-rejection) |
| TMUI login page appears via the portal but the session drops / won't submit | Session-pinning still on | [Proxied TMUI session drops](#proxied-tmui-session-drops) |
| A non-admin's REST call returns 401 but you expected read-only access | Guest role is denied REST by design | [Guest returns 401 to REST](#guest-returns-401-to-rest) |
| OpenBao container crash-loops, log `disable_mlock ... dropped support` | `disable_mlock` in the prod HCL | [OpenBao crash-loops](#openbao-crash-loops) |
| OpenBao container crash-loops, log `vault.db: permission denied` | Root-owned raft volume | [OpenBao crash-loops](#openbao-crash-loops) |
| Script reaches the BIG-IP step then errors `BIGIP_PASS: export ...` | `.env` empty value clobbered the injected pw | [BIGIP_PASS unset mid-script](#bigip_pass-unset-mid-script) |
| BIG-IP LDAP query fails `No such object (32)` for the bind account | osixia deny-all catch-all ACL | [Bind account cannot search](#bind-account-cannot-search) |
| APM group branch always empty / user always denied on group | `memberOf` is operational, not returned | [memberOf never returned](#memberof-never-returned) |

## SSO password not found
`websso` logging `Could not find SSO password for user` in `/var/log/apm` is **not an SSO
misconfiguration**. The form-SSO agent is working correctly; it was handed an empty
`session.sso.token.last.password` because the OpenBao credential fetch never produced one.
The session still reaches the webtop, which is what makes this failure look like an SSO bug
instead of a broker bug.

Three causes, in the order worth checking:

1. **The iRule is pointing at the wrong OpenBao address.** `WARDEN_HOST_IP` is rendered
   into the rule body at upload time, so a stale value survives until the rule is rebuilt.
   The iRule records its own failure — read the session variable rather than guessing:
   ```bash
   curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" -X POST -H 'Content-Type: application/json' \
     "https://${BIGIP_MGMT}/mgmt/tm/util/bash" \
     -d '{"command":"run","utilCmdArgs":"-c \"for k in $(sessiondump --list | awk {print\\$1}); do sessiondump --key $k --allkeys | grep warden; done\""}'
   ```
   `warden.fetch_err = connect-failed` means the TCP sideband to `<WARDEN_HOST_IP>:8200`
   never opened; `parse-failed` means OpenBao answered but the body held no `"password"`.
2. **The scoped token is dead or expired.** It is periodic (`period=768h`) and dies
   silently if it is not renewed inside its period — the webtop keeps working, only the
   password comes back empty. Renew it and confirm a TTL comes back:
   ```bash
   ./scripts/renew-apm-token.sh
   ```
   A non-zero exit means the token is gone: mint a new one and rebuild the front door with
   `./bigip/run-apm-build.sh`, which writes the fresh token into `warden_openbao_dg`.
3. **There is no static role for that CN.** The fetch is per-CN, so a principal who was
   issued a certificate but never given a static role fails only for that user:
   ```bash
   ./scripts/configure-openbao-static.sh <CN>
   ```

## Everyone lands read-only
Authentication succeeds, every user reaches the webtop and TMUI, and every one of them is
Guest. Nothing logs an error, because nothing failed: the BIG-IP evaluated `remote-role`,
found no match, and applied the default role it was told to apply
([ADR 0004](../adr/0004-authorization-on-bigip-remote-role.md)).

The cause is almost always the mapping attribute rather than the group. **The BIG-IP
evaluates `remote-role` against the attributes its own default LDAP search returns, and it
does not request attributes by name.** Any attribute the directory only returns *on
request* is therefore invisible to it — including an operational `memberOf` such as the one
OpenLDAP's memberof overlay produces. Mapping on it silently degrades every user to Guest,
which was verified in-lab.

Two checks, in this order:

1. Confirm what the BIG-IP actually sees, from the host, using a default search:
   ```bash
   scripts/preflight-directory.sh
   ```
   It tests both traps — that the mapping attribute comes back from a default search, and
   that the **privileged** accounts (not the identity entries) are the ones carrying it.
2. Read the decision from the device itself rather than inferring it:
   ```bash
   # on the target BIG-IP
   grep pam_bigip_authz /var/log/secure | tail -2
   ```
   `role 0 (Administrator)` versus `level=Guest` is the authoritative answer.

Where `memberOf` is unusable, map on a real stored attribute the privileged accounts carry
— `WARDEN_ADMIN_ROLE_ATTRIBUTE=employeeType=warden-admins` is what bundled mode uses. Full
matrix per directory type in [../directory.md](../directory.md).

## Seeding rejected by the directory
`ldap_add: Server is unwilling to perform (53)` with `no global superior knowledge` means
the entry being added sits **outside the directory's own suffix**. The server has no
authority over that DN and no referral to hand back, so it refuses rather than guesses. In
practice this is always a `BASE_DN` that does not match the directory: the LDIFs are
templated from it, so one wrong value makes every entry land outside the tree.

Compare the two directly — the suffix the server holds against the value Warden is
templating with:
```bash
docker exec -i openldap ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -b '' -s base namingContexts
grep ^BASE_DN .env
```
They must agree. Fix `.env`, then re-run the seeding step; on a bundled directory whose
volume was created with the wrong suffix, the volume itself carries it, so
`./teardown.sh --stack --purge --yes` followed by a fresh deploy is faster than repairing
it in place.

## Static role points at a missing account
OpenBao returning `LDAP Result Code 32 "No Such Object"` from `ldap/rotate-role/<CN>` or
`ldap/static-cred/<CN>` is the directory's answer, relayed: **the privileged account the
static role names does not exist.** OpenBao is configured correctly and its bind works —
there is simply nothing at
`<WARDEN_PRIV_DN_ATTR>=<CN>,<WARDEN_PRIV_SEARCH_BASE>` to rotate.

Usually an earlier seeding step failed and was not noticed. Confirm the account is really
absent before touching OpenBao:
```bash
ldapsearch -x -LLL -H "ldap://${WARDEN_LDAP_HOST}" -D "${WARDEN_DIR_ADMIN_DN}" \
  -w "${WARDEN_DIR_ADMIN_PW}" -b "${WARDEN_PRIV_SEARCH_BASE}" dn
```
If the privileged entries are missing, re-apply the privileged-account LDIFs and re-create
the role — the role write and the first rotation are one step:
```bash
. ./scripts/lib/ldif.sh
ldif_apply warden-users.ldif ldap/warden-users.ldif
./scripts/configure-openbao-static.sh <CN>
```
In external mode Warden creates nothing in your directory: the account has to exist in
`WARDEN_PRIV_SEARCH_BASE` before the static role can be defined over it
([../directory.md](../directory.md)).

## Reserved-address rejection
APM Portal Access refuses to proxy to any self-IP, mgmt IP, virtual-address, or
device-trust address (`tmsh list cm device`). Point the Portal Access resource at a
non-routable façade IP fronted by a shadow VS — see
[ADR 0003](../adr/0003-shadow-facade-portal-targets.md). Decode APM error codes on the box
with `error_strings.inc`, not from the apm log alone.

## Proxied TMUI session drops
The portal engine's SNAT source alternates across internal self-IPs on parallel
connections; TMUI's inbound-IP checks then kill the session. Turn both off on both units:
```bash
# sys db + sys httpd, both units, then save
curl -sk -u admin:<pw> -X PATCH -d '{"value":"false"}' https://<bigip>/mgmt/tm/sys/db/httpd.matchclient
curl -sk -u admin:<pw> -X PATCH -d '{"authPamValidateIp":"off"}' https://<bigip>/mgmt/tm/sys/httpd
```
Serial `curl` never reproduces this — test in a real browser.

## Guest returns 401 to REST
F5's **Guest** role is denied the iControl REST API by design. A 401 from a Guest user is
expected, not a failure — Guest still gets read-only TMUI. Verify the role from the target's
`/var/log/secure` `pam_bigip_authz` "level=" line, not a REST probe. See
[ADR 0004](../adr/0004-authorization-on-bigip-remote-role.md).

## OpenBao crash-loops
Two distinct causes (`docker logs openbao`):
- `disable_mlock ... dropped support` — remove the `disable_mlock` line from
  `openbao/openbao-prod.hcl` entirely. It is fatal on this 2.x build.
- `vault.db: permission denied` — the raft/log volume is root-owned but the image runs as
  uid 100. Fix and restart:
  ```bash
  docker compose -f docker-compose.yml -f docker-compose.prod.yml stop openbao
  docker run --rm -v warden_openbaodata:/data -v warden_openbaologs:/logs busybox chown -R 100:1000 /data /logs
  docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d openbao
  ```
  `openbao-init-unseal.sh` now does this chown automatically on every run.

## BIGIP_PASS unset mid-script
If you inject `BIGIP_PASS` from a secret manager (leaving it empty in `.env`), a script that
sources `.env` would clobber the injected value — the wrappers (`run-apm-build.sh`,
`revoke-all.sh`) preserve it across the source, so run BIG-IP-touching work through them
rather than the underlying scripts directly. For the demo, just set `BIGIP_PASS` in `.env`.

## Bind account cannot search
osixia/openldap ships a deny-all catch-all ACL, so `cn=bigip-bind` cannot read `ou=users`
(BIG-IP sees `No such object (32)`). Apply the read grant:
```bash
docker exec -i openldap ldapmodify -Y EXTERNAL -H ldapi:/// < ldap/acl-bigip-bind.ldif
```

## memberOf never returned
`memberOf` is an operational attribute — a default LDAP query does not return it, so any
branch reading `session.ldap.last.attr.memberOf` is always empty. You can still *filter* on
it. Authorization no longer depends on it anyway — see
[ADR 0004](../adr/0004-authorization-on-bigip-remote-role.md). The same property is what
breaks a `memberOf`-based `remote-role` mapping on OpenLDAP:
[Everyone lands read-only](#everyone-lands-read-only).

## Escalation
If a failure is not covered here: capture `docker logs openbao`, the target's `/var/log/apm`
and `/var/log/secure`, and the exact command + output. Do not force a live BIG-IP auth
change to "unstick" a session — use the kill-switch runbook.
