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

## Findings during execution (Phase 1)
- **openbao mount path:** the image reserves `/openbao` (declares `/openbao/logs`,
  `/openbao/data` volumes). Mounting the repo at `/openbao:ro` made it read-only and
  the container refused to start. Moved the config mount to **`/pua:ro`**.
- **openldap certs mount must be writable:** osixia/openldap 1.5.0 `chown`s
  `/container/service/slapd/assets/certs` on startup; with `:ro` it dies with
  "Read-only file system". Dropped `:ro` from that mount (certs are lab material).
  Also set `certs/ldap.key` to 0644 so slapd (uid 911) can read it.
- **OpenBao 2.6.1 audit is declarative-only:** `bao audit enable` (API/CLI) is
  rejected — "cannot enable audit device via API; use declarative, config-based audit
  device management instead". Added **`openbao/openbao.hcl`** with an `audit "file"`
  stanza (requires `type`, `path`, and an `options { file_path }` block) and load it via
  `server -dev -config=/pua/openbao.hcl`. Audit log path is now
  `/openbao/logs/openbao-audit.log` (was `/tmp/openbao-audit.log` in the runbook).
- **dev-mode OpenBao is ephemeral:** every `openbao` container recreate wipes the
  in-memory state, so `scripts/configure-openbao.sh` must be re-run after any recreate.
  Acceptable for the PoC (runbook flags dev mode as PoC-only); harden with a real
  storage backend for anything persistent.
- `username_template='pua-{{random 10 | lowercase}}'` accepted as-is (no fallback needed).
- **GATE 1A: PASSED** — issue -> directory entry (+employeeType) -> LDAPS bind ->
  revoke -> entry gone + bind rejected -> issuance in the audit log.

## Findings during execution (Phase 1, BIG-IP)
- **RUNBOOK GAP — bind account needs a read ACL (added `ldap/acl-bigip-bind.ldif`):**
  the runbook's `seed.ldif` creates `cn=bigip-bind` but osixia/openldap ships a
  deny-all catch-all ACL (`{2} to * ... by * none`). `bigip-bind` (a plain
  inetOrgPerson) therefore could NOT search `ou=users` — BIG-IP's user-DN lookup
  returned "No such object (32)" and remote auth would have failed at the search step.
  Fix: an `olcAccess` grant for `bigip-bind` read on `dn.subtree="ou=users"`, inserted
  AFTER the `userPassword` rule (so passwords stay hidden — verified `bigip-bind` reads
  `uid`/`employeeType` but 0 `userPassword` lines) and BEFORE the catch-all. Applied via
  `ldapmodify -Y EXTERNAL -H ldapi:///` inside the container (cn=config isn't reachable
  with the directory admin bind).
- **T1.7 reachability:** bigipa's Linux host routes `10.2.20.30` directly out the
  `internal` TMM interface (`src 10.2.20.5`) — LDAPS goes over VLAN 73, not the mgmt
  gateway. TLS probe returned the correct cert (`CN=openldap.pua.lab`).
- **T1.7 credential path:** bigipa admin password fetched from the LAB OpenBao
  `kv/bigip/common` via the sanctioned `f5-onboard` AppRole (`bootstrap/f5-bigip/bin/bao.sh`),
  never stored in this repo.
- **T1.7 auth-source flip gated by the harness auto-mode guard:** all additive objects
  (cert, `auth ldap`, `remote-user`, `remote-role`) applied via REST from Nora, but
  `PATCH /mgmt/tm/auth/source {type:ldap}` was classifier-blocked as a live auth
  mutation. Per operator decision the flip is run by hand on bigipa
  (`modify auth source { type ldap } ; save sys config`). admin/root stay local, so
  there is no lockout risk. GATE 1B tests run after the flip.
- **OpenBao lease revoke is ASYNCHRONOUS** ("All revocation operations queued
  successfully!") — the ephemeral LDAP entry is deleted a beat *after* `bao lease revoke`
  returns (observed ~1-2s). Tests must POLL for deletion, not check once immediately;
  `validate-phase1.sh` (step 5) and `gate1b-verify.sh` (step 4) now poll up to 10-12s.
  Operational note: revocation ends *future* logins with a small delay, not instantly —
  established sessions are still cut by Guacamole/APM session kill (runbook invariant 4).

## (10) Portal Access target must not be a cluster address (APM reserved-address guard)
Bookmark click died on `/vdesk/my.acl.php3?errorcode=17` with apm log
`01490585 ... rejected because it points to reserved address`. APM portal access refuses
to proxy to any address bigipa considers cluster-reserved: its own self-IPs and
virtual-addresses, mgmt IPs, and the device-trust addresses of ALL cluster members
(configsync/mirror/failover-unicast — see `tmsh list cm device`). 10.2.20.6 is bigipb's
configsync+mirror+unicast address, hence rejected. No sys db override exists (swept sys db
for reserved/rewrite/portal/apm knobs). Fix: target bigipb's EXTERNAL self-IP 10.2.10.6
instead — it appears nowhere in bigipa's config or device trust, and TMUI already serves
on it with the existing `allow-service default` port lockdown (verified 200). One-line
change: BIGIPB default in phase2-apm-dakota-rest.sh.

## (12) Shadow façade VSs replace the external-self-IP portal target (security)
Deviation 10 pointed the bigipb bookmark at the EXTERNAL self-IP 10.2.10.6 — that works,
but it depends on TMUI being reachable on the external VLAN, which is exposure we do not
want. Reworked to the shadow-VS pattern proven on the Nora build (bigip-apm-cert-ldap
role, K31750304): portal resources target RFC5737 TEST-NET façades that are NOT in APM's
reserved set — 192.0.2.5 ("bigipa TMUI", NEW bookmark) and 192.0.2.6 ("bigipb TMUI") —
and plain LTM shadow VSs on those IPs (TCP-only, TLS passthrough, all VLANs, snat automap)
steer the last hop with an iRule `node`: 127.0.0.1:443 for A (= the unit serving the
portal), bigipb internal self-IP 10.2.20.6:443 for B (VLAN 73 only; the APM reserved
check does not apply to LTM steering). A pool cannot hold a self-IP member, hence `node`;
needs tmm.tcl.rule.node.allow_loopback_addresses=true (build sets it). Both session-pin
knobs (sys db httpd.matchclient, sys httpd auth-pam-validate-ip) must be off on both
units for proxied TMUI sessions to survive — set 2026-07-27. FOLLOW-UP: with nothing
depending on external-VLAN TMUI anymore, tighten ext self-IP allow-service (operator).
