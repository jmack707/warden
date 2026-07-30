# Runbook — Browser click-through verification

The final human confirmation: that both webtop bookmarks auto-login and that role
enforcement is correct in a real browser. `curl` cannot exercise the Portal Access rewrite
+ SSO form submit end-to-end.

_Last validated: 2026-07 against TMOS 21.1.0._

## When to use this
After any APM rebuild ([../../deploy.md](../../deploy.md)) or authorization change.

## Prerequisites
- An operator workstation with `libnss3-tools` installed (`pk12util`/`certutil`);
  `scripts/import-browser-certs.sh` exits immediately if `pk12util` is missing. Run it as
  your normal user, not root — it writes into that user's Firefox profiles and Chrome/Chromium
  NSS DB, and at least one browser profile must already exist.
- `scp`/SSH access to the Warden VM as the account you pass in `WARDEN_VM`. The import script
  pulls `clients/<user>.p12` and `certs/ca.crt` from `WARDEN_REMOTE_DIR` (default
  `/opt/warden`), so those bundles must already exist there: bundled mode generates them via
  `./deploy.sh --stack` (`scripts/gen-test-users.sh`), external mode via
  `scripts/gen-client-certs.sh <CN> …`.
- A completed APM build ([../../deploy.md](../../deploy.md)) — the webtop and both TMUI
  bookmarks have to exist before there is anything to click — and HTTPS reachability from the
  workstation to `WARDEN_APM_VIP`.
- BIG-IP admin credentials (`BIGIP_USER`/`BIGIP_PASS`) if you intend to confirm the resulting
  APM sessions or read `/var/log/apm` on bigipa while diagnosing a failure.

## Procedure
1. On the operator workstation, import the test client certs:
   ```bash
   WARDEN_VM=<user>@<warden-vm-ip> scripts/import-browser-certs.sh   # p12 pass: warden  (alice.admin.p12 also accepts: alice)
   ```
2. Browse to `https://<WARDEN_APM_VIP>/` and select the **alice.admin** certificate.
3. On the webtop, click the **bigipa TMUI** bookmark, then the **bigipb TMUI** bookmark.
4. Repeat from a fresh browser profile selecting the **bob.user** certificate.

## Verification
Expected:
- **alice.admin** — lands on the webtop; each bookmark auto-logs-in to that unit's TMUI as
  **Administrator** (no login prompt), full menus, Create/Update controls present.
- **bob.user** — lands on the webtop; each bookmark opens TMUI **read-only** (Guest): menus
  visible, Create/Update controls absent or greyed.
- **carol.expired** — the cert is rejected at TLS; no webtop.

A first attempt immediately after a rebuild can transiently deny (`errorcode=19`) due to
policy-apply lag — close and retry once.

The click-through itself is the evidence, but two commands confirm the preconditions and the
result without a screenshot:

```bash
# on the workstation: the three Warden certs are in the browser store
certutil -L -d "sql:$HOME/.pki/nssdb"
# on the Docker host: each successful webtop login leaves a live APM session on bigipa
curl -sk -u admin:<bigip-admin-pw> -X POST https://<bigip-a-mgmt-ip>/mgmt/tm/util/bash \
  -d '{"command":"run","utilCmdArgs":"-c \"sessiondump --list\""}'
```

## Rollback
None — read-only verification. Nothing on the BIG-IP is changed by clicking through it; the
only mutation is the workstation's own NSS cert store, and it is reversible there:

```bash
certutil -L -d "sql:$HOME/.pki/nssdb"                                  # what the import added
certutil -D -n '<nickname-from-the-list>' -d "sql:$HOME/.pki/nssdb"    # optional: drop one back out
```

If a bookmark shows the TMUI login page but does not submit, that is the SSO step: pull the
**websso** log on bigipa (`/var/log/apm`) and see
[../troubleshooting.md](../troubleshooting.md).

## Escalation
Persistent failure after a retry: capture the effective URL, the on-screen error/session
reference number, and bigipa `/var/log/apm` (websso lines), then raise with the lab operator.
