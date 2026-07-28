# Runbook — Revoke a session everywhere (kill switch)

End a principal's access: invalidate future logins and cut a live TMUI session.

_Last validated: 2026-07 against TMOS 21.1.0, OpenBao 2.x._

## When to run
A credential is suspected compromised, a session must end now, or an access grant is being
withdrawn. Rotate/revoke ends *future* logins; a live APM/TMUI session is cut by the APM
step. (An already-established SSH session is ended by the operator on the box — the BIG-IP
has no remote "kill SSH session"; rotation stops the next login.)

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

## Escalation
If a cut reports failure (non-zero HTTP), capture the script output and check the relevant
service ([../troubleshooting.md](../troubleshooting.md)); the likely causes are OpenBao
sealed or the BIG-IP unreachable.
