# Warden — Two-Phase Build & Deploy Runbook (v3, Claude Code edition)

> **AS-BUILT:** this is the original build plan. For what is actually deployed now
> (deviations 1–16 applied), see **ARCHITECTURE.md**; per-change rationale in DEVIATIONS.md.


> Task labels: **[AGENT]** (Claude Code executes), **[AGENT-IF-ACCESS]** (executable
> only with BIG-IP creds/reachability, else emit commands), **[HUMAN]** (GUI/judgment).
> Do not proceed past a **GATE** until its checks pass. Dakota-specific parameter
> overrides and substitutions are tracked in `DEVIATIONS.md`.

## Project context
Open-source replacement for F5 PUA (Privileged User Access), hybrid design:
- **Phase 1 — OSS credential core:** OpenBao's LDAP secrets engine mints ephemeral,
  leased LDAP accounts in OpenLDAP; a lab BIG-IP validates them over LDAPS for both SSH
  and TMUI; Guacamole provides clientless SSH. Zero custom code in the credential path.
- **Phase 2 — APM front door:** BIG-IP APM adds CAC/PIV (On-Demand Cert Auth),
  credential injection (user never sees the password), reverse-proxied TMUI with form
  SSO, and instant mid-session termination via the APM session table. Phase 1 unchanged.

### Invariants — do not violate
1. The **target** BIG-IP needs no APM/LTM provisioning in Phase 1; only base TMOS auth.
2. `admin`/`root` on any BIG-IP always remain local (recovery path). Never modify them.
3. Ephemeral credentials, bind passwords, and BIG-IP credentials are **never committed**.
4. Lease revocation ends *future* logins; established sessions are terminated by
   Guacamole session kill (SSH) and, in Phase 2, APM session deletion (TMUI).

## PHASE 1 — OSS credential core
- **T1.1 [AGENT]** Scaffold the repo (see layout). Acceptance: no secrets in git; dirs present.
- **T1.2 [AGENT]** `scripts/gen-certs.sh` — CA + LDAP server cert. Acceptance:
  `openssl x509 -in certs/ldap.crt -noout -ext subjectAltName` shows the lab host IP.
  The SAN **must** match how the BIG-IP addresses the directory or LDAPS fails closed.
- **T1.3 [AGENT]** `docker-compose.yml` — openbao (dev), openldap (TLS), guac stack.
  Acceptance: containers healthy; `curl ${BAO_ADDR}/v1/sys/health | jq .initialized` = true;
  `docker logs openldap` shows TLS enabled.
- **T1.4 [AGENT]** `ldap/seed.ldif` — ou=users, ou=svc, cn=bigip-bind. Acceptance:
  ldapsearch returns all three entries.
- **T1.5 [AGENT]** `scripts/configure-openbao.sh` — pw policy, ldap/config, role
  warden-admin (ttl 15m/max 1h). Acceptance: `bao read ldap/creds/warden-admin` returns
  username/password/lease_id; entry visible via ldapsearch with employeeType=warden-admins;
  `ldapwhoami` over LDAPS with the issued creds succeeds (simulates the BIG-IP bind).
- **T1.6 [AGENT]** `scripts/{issue-cred,revoke-cred,validate-phase1}.sh`.
- **GATE 1A [AGENT]:** `validate-phase1.sh` passes end-to-end, no BIG-IP. Do not start T1.7 until it does.
- **T1.7 [AGENT-IF-ACCESS]** BIG-IP target config (`bigip/phase1-target{,-rest}.{tmsh,sh}`).
  Safety: console/second admin session open before `auth source`; never touch admin/root.
- **T1.8 [HUMAN]** Guacamole SSH connection + end-to-end test (issue cred -> SSH + TMUI within TTL).
- **GATE 1B (exit) [HUMAN verifies, AGENT checklist]:** one credential works for both
  SSH and TMUI in TTL; auto-deleted at expiry (both logins then fail); revoke deletes
  immediately; non-`warden-admins` user gets no-access; local admin works with the whole
  stack stopped; issuance/revocation in the audit log, BIG-IP events in /var/log/secure.
- **Rollback (human):** `modify auth source { type local }` -> `save sys config`.
  `docker-compose down -v` removes the stack.

## PHASE 2 — APM front door
Adds an APM-provisioned gateway in front of the unchanged Phase 1 core. Agent's job is
artifact generation + verification support, not direct execution (VPE/GUI, version-sensitive).
- **T2.1 [AGENT]** `bigip/phase2-apm-notes.md` — object inventory, policy flow, OpenBao
  fetch options by TMOS version, session-kill wiring (`scripts/revoke-all.sh`, APM step stubbed).
- **T2.2 [AGENT]** Scoped OpenBao policy + token/AppRole for the APM fetch path (root
  token never embedded in a BIG-IP object). Optional CAC-attributed OIDC skeleton.
- **GATE 2A [AGENT]:** scoped token reads `ldap/creds/warden-admin`; root-token paths fail.
- **T2.3 [HUMAN]** Build APM objects in VPE (ODCA, OpenBao fetch, form SSO, webtop).
- **T2.4 [HUMAN + AGENT]** Phase 2 exit criteria (CAC -> webtop, injected TMUI login,
  SSH via Guacamole, APM session delete cuts TMUI, `revoke-all.sh` ends all three,
  audit attribution, direct-to-target blocked).

## Standing agent instructions
- Prefer editing existing files; keep changes commit-sized. Record deviations in DEVIATIONS.md.
- Never print issued passwords to logs/commits/files; `issue-cred.sh` -> stdout only.
- Capture exact `bao`/`ldap*`/REST errors before retrying. When in doubt about a BIG-IP
  mutation, stop and emit tmsh for the human instead of forcing the REST path.
