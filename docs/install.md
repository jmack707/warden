# Install — OSS credential core (Phase 1)

First-time standup of the Docker stack (OpenBao, OpenLDAP, Guacamole) on the pua-oss VM.
This is Phase 1 only; the BIG-IP APM front door is [deploy.md](deploy.md).

_Last validated: 2026-07 on Debian 13, docker.io 26.1.5 + docker-compose v2, OpenBao 2.x,
OpenLDAP (osixia) 1.5.0, Guacamole 1.6.0._

## Prerequisites
- A Linux VM on the internal lab VLAN (Dakota: `10.2.20.30`, VLAN 73) with outbound DNS
  that resolves container registries (the lab uses `1.1.1.1` to dodge the FreeIPA resolver).
- `docker.io` 26.x and the `docker-compose` v2 plugin.
- Reachability from this VM to the target BIG-IP management address on 443.

## Steps
```bash
cd /root/pua-oss
cp .env.example .env            # then edit: LAB_HOST_IP, BASE_DN, LDAP_ADMIN_PW, BIND_PW
scripts/gen-certs.sh            # CA + LDAPS server cert; SAN MUST include LAB_HOST_IP

# Guacamole needs its Postgres schema before first full start:
docker-compose up -d guac-db && sleep 5
docker run --rm guacamole/guacamole:1.6.0 /opt/guacamole/bin/initdb.sh --postgresql > initdb.sql
docker exec -i guac-db psql -U guacamole -d guacamole < initdb.sql

docker-compose up -d            # full stack
source .env
envsubst < ldap/seed.ldif | ldapadd -x -H "ldap://${LAB_HOST_IP}" \
  -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PW}"      # seed the directory
docker exec -i openldap ldapmodify -Y EXTERNAL -H ldapi:/// < ldap/acl-bigip-bind.ldif
scripts/configure-openbao.sh    # LDAP secrets engine + ephemeral role + audit device
```

> Running OpenBao in production (raft-persisted) mode instead of dev? Do the cutover in
> [operations/runbooks/openbao-cutover.md](operations/runbooks/openbao-cutover.md) after
> `configure-openbao.sh`.

## Verification
```bash
scripts/validate-phase1.sh      # GATE 1A — end-to-end, no BIG-IP
```
Expected: the script prints each check and ends green (exit 0) — an ephemeral credential is
minted, appears in OpenLDAP, and its lease revoke deletes the entry. If it exits non-zero,
stop and see [operations/troubleshooting.md](operations/troubleshooting.md); do not proceed
to the BIG-IP until GATE 1A passes.

Also confirm the stack is healthy:
```bash
docker ps --format '{{.Names}}: {{.Status}}'
```
Expected: `openbao`, `openldap`, `guacamole`, `guacd`, `guac-db` all `Up`.
