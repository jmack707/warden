# ADR 0001 — Hybrid OSS design for privileged access, no custom credential-path code

- Status: Accepted
- Date: 2026-07-10

## Context
We need open-source privileged access for BIG-IP: certificate-based authentication, a
password the user never sees, reverse-proxied access to the target's management UI, and
instant session termination. Building the credential path in bespoke code would put us on
the hook for its security.

## Decision
Compose existing, audited components instead of writing credential-handling code:
- **OpenBao** LDAP secrets engine mints/rotates credentials.
- **OpenLDAP** stores the accounts and is the single source of truth the target validates
  against.
- **BIG-IP APM** is the front door: client-cert auth, credential injection, form SSO,
  portal access, and session termination.

The only custom artifacts are declarative: iControl-REST build scripts, an APM iRule that
sideband-fetches from OpenBao, and LDIF/policy files. No component invents its own crypto
or credential storage.

## Consequences
- Security of the credential path reduces to the security of OpenBao + OpenLDAP + TMOS.
- The design splits identity from privilege (see [0002](0002-identity-privilege-split.md)).
- Every credential is effectively one-time: the next session's rotation invalidates the
  previous password everywhere at once.
- We inherit each component's quirks (APM reserved-address guard, OpenBao 2.x seal
  lifecycle, osixia ACL defaults) — captured in [../../DEVIATIONS.md](../../DEVIATIONS.md).
