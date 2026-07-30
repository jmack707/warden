# Security policy

Warden is a **demonstration** of a privileged-access pattern, not a hardened product. Read
this before running it anywhere that matters.

## Reporting a vulnerability
Report privately through GitHub's
[private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository (Security → Report a vulnerability). Please do not open a public issue for
anything exploitable.

Include what you need to make the finding reproducible: the affected component, the
configuration you ran (redact real addresses and credentials), and the impact you observed.
Expect an acknowledgement within a week. There is no bounty — this is a lab project.

If the issue is in **OpenBao**, **OpenLDAP**, or **BIG-IP/TMOS** rather than in this repo's
configuration of them, report it to that project or to F5 directly; those paths are faster and
reach the people who can fix it.

## What this demo deliberately does not do
These are known, intentional trade-offs of the default configuration. They are not
vulnerabilities in the demo, and they *are* things to fix before anything resembling
production use.

- **OpenBao runs in dev mode** by default: in-memory storage, a root token of `root`, and HTTP
  rather than TLS on `:8200`. State is lost when the container stops. A raft-persisted,
  auto-unsealing configuration is provided — see
  [ADR 0005](docs/adr/0005-openbao-persisted-auto-unseal.md) and
  [the cutover runbook](docs/operations/runbooks/openbao-cutover.md).
- **The OpenBao listener is plain HTTP** on the internal network, so the iRule sideband that
  fetches credentials is unencrypted on the wire. Enabling TLS touches the iRule, the wrapper
  scripts and `.env` together — see the "Pending" note in [docs/upgrade.md](docs/upgrade.md).
- **`BIGIP_PASS` in `.env`** is convenient for a demo. Every wrapper honours the value
  injected from the environment instead, which is how it should be supplied in earnest.
- **The credential-fetch iRule is PoC-grade**: a plaintext sideband with regex JSON
  extraction. Production would use iRulesLX with a real JSON parser, TLS with a pinned CA, and
  the scoped token held in an APM system variable rather than a data group.
- **The demo CA and client certificates are generated locally** with no revocation
  infrastructure. `certs/` and `clients/` are gitignored; never commit them, and never reuse
  the demo CA for anything real.
- **Test principals ship with known-purpose passwords** set from `.env`. They exist to
  demonstrate the admin/read-only/rejected outcomes and have no place outside a lab.

## What it does get right, and should keep getting right
Please treat regressions in these as bugs worth reporting:

- The operator never receives the privileged password; OpenBao rotates it and APM injects it.
- The token stored on the BIG-IP is scoped to reading `ldap/static-cred/*` and rotating
  `ldap/rotate-role/*` — nothing else. `scripts/configure-openbao-phase2.sh` with `GATE2A=1`
  asserts that the scope is actually enforced.
- `admin` and `root` on the BIG-IP stay **local**. Switching the auth source cannot lock you
  out, and teardown restores local auth before removing the LDAP configuration.
- Authorization is decided by the target BIG-IP's `remote-role`, so the elevation decision is
  auditable on the device being administered. Anyone who authenticates without matching the
  admin group gets read-only.
- Warden creates nothing in an external directory, and teardown never modifies one.

## Supported versions
The `main` branch is the only supported version. Validated component versions are recorded in
each procedure's `Last validated` stamp and in [DEVIATIONS.md](DEVIATIONS.md).
