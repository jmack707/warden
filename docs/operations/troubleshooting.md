# Troubleshooting

Symptom-first. Find the row, jump to the section. Every failure here was hit during the
build; the detail lives in [../../DEVIATIONS.md](../../DEVIATIONS.md).

_Last validated: 2026-07 against TMOS 21.1.0, OpenBao 2.x._

| Symptom | Likely cause | Section |
|---|---|---|
| Webtop bookmark → `my.acl.php3?errorcode=17`, apm log `01490585 ... reserved address` | Portal target is a cluster-reserved address | [Reserved-address rejection](#reserved-address-rejection) |
| TMUI login page appears via the portal but the session drops / won't submit | Session-pinning still on | [Proxied TMUI session drops](#proxied-tmui-session-drops) |
| A non-admin's REST call returns 401 but you expected read-only access | Guest role is denied REST by design | [Guest returns 401 to REST](#guest-returns-401-to-rest) |
| OpenBao container crash-loops, log `disable_mlock ... dropped support` | `disable_mlock` in the prod HCL | [OpenBao crash-loops](#openbao-crash-loops) |
| OpenBao container crash-loops, log `vault.db: permission denied` | Root-owned raft volume | [OpenBao crash-loops](#openbao-crash-loops) |
| Script reaches the BIG-IP step then errors `BIGIP_PASS: export ...` | `.env` empty value clobbered the injected pw | [BIGIP_PASS unset mid-script](#bigip_pass-unset-mid-script) |
| Script edit had no effect after `run-dakota-apm-build.sh` | Build runs from the Nora mirror | [Build ignored my edit](#build-ignored-my-edit) |
| BIG-IP LDAP query fails `No such object (32)` for the bind account | osixia deny-all catch-all ACL | [Bind account cannot search](#bind-account-cannot-search) |
| APM group branch always empty / user always denied on group | `memberOf` is operational, not returned | [memberOf never returned](#memberof-never-returned) |

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
  docker-compose -f docker-compose.yml -f docker-compose.prod.yml stop openbao
  docker run --rm -v pua-oss_openbaodata:/data -v pua-oss_openbaologs:/logs busybox chown -R 100:1000 /data /logs
  docker-compose -f docker-compose.yml -f docker-compose.prod.yml up -d openbao
  ```
  `openbao-init-unseal.sh` now does this chown automatically on every run.

## BIGIP_PASS unset mid-script
`.env` ships `BIGIP_PASS` empty on purpose. A script that sources `.env` after the wrapper
injects the value will clobber it unless it preserves the incoming value across the source
(the APM build and `revoke-all.sh` both do). Run BIG-IP-touching scripts through their Nora
wrapper (`run-dakota-apm-build.sh`, `run-revoke.sh`), which injects the password correctly.

## Build ignored my edit
`run-dakota-apm-build.sh` executes the script from **Nora's** `/root/pua-oss` mirror, not
the VM repo. Commit on the VM, then `git -C /root/pua-oss pull --ff-only` on Nora before
rebuilding.

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
[ADR 0004](../adr/0004-authorization-on-bigip-remote-role.md).

## Escalation
If a failure is not covered here: capture `docker logs openbao`, the target's `/var/log/apm`
and `/var/log/secure`, and the exact command + output, then raise it with the lab operator
(jmack). Do not force a live BIG-IP auth change to "unstick" a session — use the kill-switch
runbook.
