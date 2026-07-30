# Runbook — Revoke a session everywhere (kill switch)

End a principal's access: invalidate future logins and cut a live TMUI session.

_Last validated: 2026-07 against TMOS 21.1.0, OpenBao 2.x._

## When to use this
A credential is suspected compromised, a session must end now, or an access grant is being
withdrawn. Rotate/revoke ends *future* logins; a live APM/TMUI session is cut by the APM
step. (An already-established SSH session is ended by the operator on the box — the BIG-IP
has no remote "kill SSH session"; rotation stops the next login.)

## Prerequisites
- Shell access on the Docker host, run from the repo root: `revoke-all.sh` reads `.env` and
  reaches OpenBao through `docker exec openbao`, so the `openbao` container must be up and
  unsealed. `python3` is required — the script uses it to build the REST payload and parse the
  response.
- `.env` populated with `BAO_TOKEN` and `BIGIP_MGMT`/`BIGIP_USER`, plus REST reachability to
  the target BIG-IP on `443`. `BIGIP_PASS` must be readable from `.env` **or** injected in the
  environment; the script asserts it before the APM cut and an injected value wins over the
  `.env` one, so a production password never has to be written to disk.
- The principal's CN as OpenBao and APM know it — the static-role name and the client-cert CN
  are the same string. For a targeted cut you also need the APM session key, or the lease ID
  for an ephemeral credential.
- For the log-side verification, shell or console access on the target BIG-IP to read
  `/var/log/secure`.

## Procedure
Run on the Docker host (reads `BIGIP_PASS` from `.env`, or inject it):
```bash
./scripts/revoke-all.sh --cn <CN>
```
Optionally target a specific live APM session:
```bash
./scripts/revoke-all.sh --cn <CN> --apm-key <session-key>
```
To also revoke an ephemeral lease, add `--lease <lease_id>`.

Find identifiers if needed:
```bash
# APM session keys on the target:
curl -sk -u admin:<pw> -X POST https://<bigip>/mgmt/tm/util/bash \
  -d '{"command":"run","utilCmdArgs":"-c \"sessiondump --list\""}'
```

## Verification
The script prints one line per cut. Confirm the credential no longer works:
```bash
grep pam_bigip_authz /var/log/secure | tail   # on the target: expect no new success for <CN>
```
Expected: OpenBao reports the static role rotated (or lease revoked); APM reports the
session deleted (or "no live session found" if none). A subsequent login with the old
password fails.

## Rollback
Revocation is intentional and not reversible per se. To restore access for `<CN>`, re-issue
normally: the next portal login rotates and injects a fresh credential (static mode), or run
`./scripts/issue-cred.sh` (ephemeral). No manual cleanup is required.

```bash
# ephemeral model — mint a fresh leased credential now
./scripts/issue-cred.sh
# static model — nothing to run; confirm the role is still there so the next login can rotate
docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN=$(grep ^BAO_TOKEN .env|cut -d= -f2) \
  openbao bao list ldap/static-role
```

## Escalation
If a cut reports failure (non-zero HTTP), capture the script output and check the relevant
service ([../troubleshooting.md](../troubleshooting.md)); the likely causes are OpenBao
sealed or the BIG-IP unreachable.
