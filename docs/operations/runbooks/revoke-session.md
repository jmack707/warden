# Runbook — Revoke a PUA session everywhere (kill switch)

End a principal's access: invalidate future logins and cut any live TMUI/SSH session.

_Last validated: 2026-07 against TMOS 21.1.0, OpenBao 2.x, Guacamole 1.6.0._

## When to run
A credential is suspected compromised, a session must end now, or an access grant is being
withdrawn. Lease revoke/rotate ends *future* logins; established sessions are cut by the
APM and Guacamole steps.

## Procedure
Run on **Nora** (fetches the BIG-IP admin pw via AppRole):
```bash
bash /root/pua-oss/bigip/run-revoke.sh --cn <CN>
```
Optionally target a specific live session / tunnel:
```bash
bash /root/pua-oss/bigip/run-revoke.sh --cn <CN> --apm-key <session-key> --guac-id <uuid>
```
To also revoke an ephemeral Phase-1 lease, add `--lease <lease_id>`.

Find identifiers if needed:
```bash
# APM session keys on the target:
curl -sk -u admin:<pw> -X POST https://<bigip>/mgmt/tm/util/bash \
  -d '{"command":"run","utilCmdArgs":"-c \"sessiondump --list\""}'
```

## Verification
The script prints one line per cut. Confirm the credential no longer works:
```bash
# on the VM: the rotated password should NOT authenticate as the old one
grep pam_bigip_authz /var/log/secure | tail   # on the target: expect no new success for <CN>
```
Expected: OpenBao reports the static role rotated (or lease revoked); APM reports the
session deleted (or "no live session found" if none); Guac reports the tunnel killed (or no
match). A subsequent login attempt with the old password fails.

## Rollback
Revocation is intentional and not reversible per se. To restore access for `<CN>`, re-issue
normally: the next portal login rotates and injects a fresh credential automatically (static
role) or run `scripts/issue-cred.sh` (ephemeral). No manual cleanup is required.

## Escalation
If a cut reports failure (non-zero HTTP, "could not obtain a Guacamole admin token"),
capture the script output and check the relevant service
([../troubleshooting.md](../troubleshooting.md)); escalate to the lab operator (jmack) if
OpenBao is sealed or the BIG-IP is unreachable.
