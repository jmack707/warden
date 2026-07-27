# ADR 0002 — Split identity from privilege in the directory

- Status: Accepted
- Date: 2026-07-23

## Context
A user's cert proves *who they are*; the credential injected into a target grants *what
they can do*. Conflating them means the identity the operator authenticates with is also
the high-privilege account whose password is rotated — surprising and hard to reason about.

## Decision
Two subtrees in OpenLDAP:
- **`ou=people`** — identity entries keyed by the cert CN. APM maps the CN here.
- **`ou=users`** — privileged *access* accounts. OpenBao owns and rotates their
  `userPassword`; the target BIG-IP validates the injected credential by binding as
  `uid=<CN>,ou=users`. `employeeType=pua-admins` marks an admin.

`cn=bigip-admins,ou=groups` is the admin group. `cn=bigip-bind,ou=svc` is the BIG-IP
search/bind account, granted read on `ou=users` but never `userPassword`.

## Consequences
- The password rotated by OpenBao is never the operator's identity credential.
- A new access account (e.g. a non-admin) is added by creating an `ou=users` entry plus an
  OpenBao static role — the identity entry in `ou=people` is untouched.
- Authorization data (admin vs not) lives on the `ou=users` account as `employeeType`,
  which the target's remote-role reads — see
  [0004](0004-authorization-on-bigip-remote-role.md).
