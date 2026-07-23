# DEVIATIONS from RUNBOOK.md (Dakota deployment)

Per the runbook's standing instruction to record every deviation.

## Environment / placement
- **Stack host:** the OSS core runs on a **dedicated VM `pua-oss` (VMID 240)** built
  on the Dakota Proxmox host, not the generic `10.1.1.10` lab default.
  - `LAB_HOST_IP=10.2.20.30`, VLAN 73 (Dakota "internal", 10.2.20.0/24), gw 10.2.20.1.
  - Debian 13 genericcloud, 4 vCPU / 8 GB / 33 GB on `nvme` lvm-thin, ovmf/EFI
    (Debian's cloud image is EFI-only), `pre-enrolled-keys=0`, cloud-init.
  - DNS pinned to `1.1.1.1` (the VLAN-73 default resolver is FreeIPA, which cannot
    resolve public registries — known Dakota gotcha).
- **Target BIG-IP:** `bigipa.dakota`, mgmt `10.2.1.5` (TMOS 21.1.0). Its HA peer
  `bigipb` (211) was left powered off; Phase 1 needs only the single target box, and
  TMOS auth-source is a device-local setting (not config-synced).

## Docker / compose
- Host uses Debian's **`docker.io` 26.1.5** + **`docker-compose` 2.26.1** (Compose v2,
  invoked as `docker-compose`). Runbook text says `docker compose`; both work here.
- **Added a bind-mount** to the `openbao` service: `./openbao:/openbao:ro`. Reason:
  `bao` is run via `docker exec openbao bao ...` (no host `bao` CLI installed), so the
  `creation.ldif`/`deletion.ldif`/`rollback.ldif`/`pw-policy.hcl` files referenced as
  `...=@/openbao/<file>` must be visible inside the container.
- Scripts run `bao` through `docker exec` rather than a host binary; `BAO_ADDR`/
  `BAO_TOKEN` are passed to the container's CLI (dev-mode root token `root`).

## BIG-IP config path
- T1.7 executed via **iControl REST** (`bigip/phase1-target-rest.sh`), credentials
  sourced from the **lab OpenBao `kv/bigip/common`** at run time (never committed).
- CA cert installed via `/mgmt/shared/file-transfer/uploads/` +
  `POST /mgmt/tm/sys/file/ssl-cert` (the REST equivalent of `create sys file ssl-cert`).
- Added a **reachability pre-flight** (`openssl s_client` from bigipa to
  `10.2.20.30:636` via `/mgmt/tm/util/bash`) before mutating auth, since system-auth
  LDAP egresses on the management plane and must route mgmt -> VyOS -> VLAN 73.

## (fill in during execution)
- <record any image-pull substitutions, parameter fallbacks, tmsh field-name fixes here>
