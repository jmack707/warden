# Install — the Warden OSS stack

Stand up OpenBao + OpenLDAP on a Docker host and configure the directory and OpenBao. The
BIG-IP front door is [deploy.md](deploy.md); `./deploy.sh` does both in one run.

_Last validated: 2026-07 on Debian 13, docker.io 26.1.5 + Docker Compose v2, OpenBao 2.x,
OpenLDAP (osixia) 1.5.0._

## Prerequisites
- A Linux host with `docker` + the Compose **v2 plugin**, reachable by the BIG-IP on `:636`
  (LDAPS) and `:8200` (OpenBao). Every script and runbook invokes it as **`docker compose`**
  (Debian/Ubuntu: `sudo apt-get install -y docker-compose-v2`). The standalone v1
  `docker-compose` binary is end-of-life and unsupported — alias it to `docker compose` if
  that is all a host has.
- `openssl`, `ldap-utils`, `jq`, and `gettext` (`envsubst`) on the host.
- REST reachability from this host to the BIG-IP management address on `443`.

## One-command path
```bash
cp .env.example .env      # fill in the <angle-bracket> values
./deploy.sh               # runs everything below, then the BIG-IP build
```

## Stack only
`deploy.sh` takes the same three forms as `teardown.sh`, so the OSS core can be stood up
without touching a BIG-IP (`BIGIP_*` need not be set):

```bash
./deploy.sh --stack       # certs, containers, directory, OpenBao
./deploy.sh --bigip       # the BIG-IP half, once the stack is up
```

## Manual path
To build the same thing step by step — with what each layer is for and how to prove it works
before moving on — follow [manual-build.md](manual-build.md). It is the teaching version of
`deploy.sh`, and you can hand back to the scripts at any point.

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
