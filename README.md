# pua-oss — OSS replacement for F5 PUA (Dakota lab deployment)

Hybrid privileged-access design. See **RUNBOOK.md** for the authoritative two-phase
build; **DEVIATIONS.md** for how this Dakota deployment differs from the generic lab.

- **Phase 1 (this stack):** OpenBao LDAP secrets engine mints ephemeral, leased LDAP
  accounts in OpenLDAP; `bigipa.dakota` validates them over LDAPS for SSH + TMUI;
  Guacamole gives clientless SSH.
- **Phase 2:** BIG-IP APM front door (CAC/PIV, credential injection, form SSO). See
  `bigip/phase2-apm-notes.md`.

## Layout / where things run
- Runs on the `pua-oss` VM, `10.2.20.30` (Dakota VLAN 73). Target BIG-IP `10.2.1.5`.
- Copy `.env.example` -> `.env` (gitignored) and fill in. Never commit `.env`, keys,
  or issued passwords.

## Quickstart
```bash
scripts/gen-certs.sh                     # T1.2  TLS material (SAN must match LAB_HOST_IP)
docker-compose up -d guac-db && sleep 5  # T1.3  init Guacamole schema, then full stack
docker run --rm guacamole/guacamole:1.6.0 /opt/guacamole/bin/initdb.sh --postgresql > initdb.sql
docker exec -i guac-db psql -U guacamole -d guacamole < initdb.sql
docker-compose up -d
source .env; envsubst < ldap/seed.ldif | ldapadd -x -H "ldap://${LAB_HOST_IP}" \
  -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PW}"      # T1.4
scripts/configure-openbao.sh             # T1.5
scripts/validate-phase1.sh               # GATE 1A (must pass before touching BIG-IP)
BIGIP_PASS=... bigip/phase1-target-rest.sh   # T1.7
scripts/issue-cred.sh                     # issue an ephemeral credential (stdout only)
```
