# ADR 0004 — Authorize on the BIG-IP remote-role, not in the APM policy

- Status: Accepted
- Date: 2026-07-27

## Context
Originally APM gated access on group membership by folding it into the LDAP query filter
`(&(uid=%{session.custom.cn})(memberOf=<group>))` — only admins reached the webtop. The
requirement changed: any valid cert identity should reach the webtop/TMUI, and the *target
BIG-IP* should decide the role — `bigip-admins` → administrator, everyone else → read-only.

## Decision
- APM LDAP query becomes identity-only: `(uid=%{session.custom.cn})`. Existence, not
  membership, is the APM gate.
- The target BIG-IP does authorization via remote-role: `remote-role pua_admins` matches
  `employeeType=pua-admins` → Administrator; `remote-user default-role` is set to **guest**
  (read-only) for everyone else. Applied on both units (device-local, not synced).

This is still group-based authorization: `bigip-admins` members carry the `employeeType`
stamp on their `ou=users` access account, so no `check-roles-group`/`group-dn` machinery is
needed. A non-admin (bob.user) gets an `ou=users` account with no `employeeType`.

## Consequences
- Verify the role from the target's `/var/log/secure` `pam_bigip_authz` "level=" line, not
  a REST probe: F5's **Guest role is denied the iControl REST API by design** (a Guest REST
  call returns 401), but Guest still gets read-only TMUI — the intended experience.
- Verified: alice.admin → Administrator, bob.user → Guest, carol.expired → TLS reject.
- admin/root stay local (unchanged), so there is no lockout risk from this change.
