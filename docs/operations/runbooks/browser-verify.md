# Runbook — Browser click-through verification

The final human confirmation: that both webtop bookmarks auto-login and that role
enforcement is correct in a real browser. `curl` cannot exercise the Portal Access rewrite
+ SSO form submit end-to-end.

_Last validated: 2026-07 against TMOS 21.1.0._

## When to run
After any APM rebuild ([../../deploy.md](../../deploy.md)) or authorization change.

## Procedure
1. On the operator workstation, import the test client certs:
   ```bash
   scripts/import-browser-certs.sh      # p12 pass: warden  (alice.admin.p12 also accepts: alice)
   ```
2. Browse to `https://10.2.20.50/` and select the **alice.admin** certificate.
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

## Rollback
None — read-only verification. If a bookmark shows the TMUI login page but does not submit,
that is the SSO step: pull the **websso** log on bigipa (`/var/log/apm`) and see
[../troubleshooting.md](../troubleshooting.md).

## Escalation
Persistent failure after a retry: capture the effective URL, the on-screen error/session
reference number, and bigipa `/var/log/apm` (websso lines), then raise with the lab operator
(jmack).
