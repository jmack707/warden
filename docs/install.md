# Install — the Warden OSS stack

Stand up OpenBao + OpenLDAP on a Docker host and configure the directory and OpenBao. The
BIG-IP front door is [deploy.md](deploy.md); `./deploy.sh` does both in one run.

_Last validated: 2026-07 on Debian 13, docker.io 26.1.5 + docker-compose v2, OpenBao 2.x,
OpenLDAP (osixia) 1.5.0._

## Prerequisites
- A Linux host with `docker` + `docker-compose` v2, reachable by the BIG-IP on `:636`
  (LDAPS) and `:8200` (OpenBao).
- `openssl`, `ldap-utils`, `jq`, and `gettext` (`envsubst`) on the host.
- REST reachability from this host to the BIG-IP management address on `443`.

## One-command path
```bash
cp .env.example .env      # fill in the <angle-bracket> values
./deploy.sh               # runs everything below, then the BIG-IP build
```

## Manual path (what deploy.sh does, stack only)
```bash
cp .env.example .env      # edit WARDEN_HOST_IP, WARDEN_DOMAIN/BASE_DN, LDAP_ADMIN_PW, BIND_PW
./scripts/gen-certs.sh    # CA + LDAPS server cert; SAN is built from WARDEN_HOST_IP
docker-compose up -d      # OpenBao + OpenLDAP
source .env
envsubst < ldap/seed.ldif | ldapadd -x -H "ldap://${WARDEN_HOST_IP}" \
  -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PW}"                 # seed the directory
docker exec -i openldap ldapmodify -Y EXTERNAL -H ldapi:/// < ldap/acl-bigip-bind.ldif
./scripts/configure-openbao.sh    # LDAP secrets engine + audit device
```

> To run OpenBao raft-persisted instead of dev mode, do the cutover in
> [operations/runbooks/openbao-cutover.md](operations/runbooks/openbao-cutover.md) after
> `configure-openbao.sh`.

## Verification
```bash
./scripts/validate-phase1.sh      # end-to-end credential core, no BIG-IP
docker ps --format '{{.Names}}: {{.Status}}'
```
Expected: `validate-phase1.sh` ends green (exit 0) — a credential is minted, appears in
OpenLDAP, and its revoke deletes the entry; `openbao` and `openldap` both `Up`. If it exits
non-zero, stop and see [operations/troubleshooting.md](operations/troubleshooting.md) before
touching the BIG-IP.
