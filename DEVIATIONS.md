# Engineering notes — reference build

Hard-won specifics and gotchas from the private reference deployment this was first
built on. Not
customer-facing config — the reusable knowledge is distilled into [docs/adr/](docs/adr/)
and [docs/operations/troubleshooting.md](docs/operations/troubleshooting.md). Kept as the
record of *why* each non-obvious choice was made.

## Environment / placement
- **Stack host:** the OSS core ran on a **dedicated VM** built on the reference site's
  Proxmox host, not the generic `10.1.1.10` lab default.
  - `WARDEN_HOST_IP=10.2.20.30`, VLAN 73 (that site's "internal" arm, 10.2.20.0/24), gw 10.2.20.1.
  - Debian 13 genericcloud, 4 vCPU / 8 GB / 33 GB on `nvme` lvm-thin, ovmf/EFI
    (Debian's cloud image is EFI-only), `pre-enrolled-keys=0`, cloud-init.
  - DNS pinned to `1.1.1.1` (the VLAN-73 default resolver is FreeIPA, which cannot
    resolve public registries — a gotcha specific to that site).
- **Target BIG-IP:** `bigipa`, mgmt `10.2.1.5` (TMOS 21.1.0). Its HA peer
  `bigipb` (211) was left powered off; Phase 1 needs only the single target box, and
  TMOS auth-source is a device-local setting (not config-synced).

## Docker / compose
- **Compose is invoked as `docker compose` (v2 plugin form) everywhere** — scripts, docs and
  runbooks. That is the single supported spelling; the standalone v1 `docker-compose` binary
  is end-of-life and is not used. `deploy.sh` checks `docker compose version` in its preflight
  and fails with the install hint if it is absent. Only the *filenames* keep the hyphen
  (`docker-compose.yml`, `docker-compose.prod.yml`) — that is Compose's own convention.
  On Debian install `docker-compose-v2` (Debian 13 ships Compose 2.26.1 as the plugin). If a
  host has only the standalone binary, alias it (`docker-compose` → `docker compose`) rather
  than editing the scripts.
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
  the container refused to start. Moved the config mount to **`/warden:ro`**.
- **openldap certs mount must be writable:** osixia/openldap 1.5.0 `chown`s
  `/container/service/slapd/assets/certs` on startup; with `:ro` it dies with
  "Read-only file system". Dropped `:ro` from that mount (certs are lab material).
  Also set `certs/ldap.key` to 0644 so slapd (uid 911) can read it.
- **OpenBao 2.6.1 audit is declarative-only:** `bao audit enable` (API/CLI) is
  rejected — "cannot enable audit device via API; use declarative, config-based audit
  device management instead". Added **`openbao/openbao.hcl`** with an `audit "file"`
  stanza (requires `type`, `path`, and an `options { file_path }` block) and load it via
  `server -dev -config=/warden/openbao.hcl`. Audit log path is now
  `/openbao/logs/openbao-audit.log` (was `/tmp/openbao-audit.log` in the runbook).
- **dev-mode OpenBao is ephemeral:** every `openbao` container recreate wipes the
  in-memory state, so `scripts/configure-openbao.sh` must be re-run after any recreate.
  Acceptable for the PoC (runbook flags dev mode as PoC-only); harden with a real
  storage backend for anything persistent.
- `username_template='warden-{{random 10 | lowercase}}'` accepted as-is (no fallback needed).
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
  gateway. TLS probe returned the correct cert (`CN=openldap.warden.lab`).
- **T1.7 credential path:** bigipa admin password fetched from the LAB OpenBao
  `kv/bigip/common` via the sanctioned `f5-onboard` AppRole (`bootstrap/f5-bigip/bin/bao.sh`),
  never stored in this repo.
- **T1.7 auth-source flip gated by the harness auto-mode guard:** all additive objects
  (cert, `auth ldap`, `remote-user`, `remote-role`) applied via REST from the build host, but
  `PATCH /mgmt/tm/auth/source {type:ldap}` was classifier-blocked as a live auth
  mutation. Per operator decision the flip is run by hand on bigipa
  (`modify auth source { type ldap } ; save sys config`). admin/root stay local, so
  there is no lockout risk. GATE 1B tests run after the flip.
- **OpenBao lease revoke is ASYNCHRONOUS** ("All revocation operations queued
  successfully!") — the ephemeral LDAP entry is deleted a beat *after* `bao lease revoke`
  returns (observed ~1-2s). Tests must POLL for deletion, not check once immediately;
  `validate-phase1.sh` (step 5) and `gate1b-verify.sh` (step 4) now poll up to 10-12s.
  Operational note: revocation ends *future* logins with a small delay, not instantly —
  established sessions are still cut by the APM session kill.

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
change: BIGIPB default in apm-build.sh.

## (12) Shadow façade VSs replace the external-self-IP portal target (security)
Deviation 10 pointed the bigipb bookmark at the EXTERNAL self-IP 10.2.10.6 — that works,
but it depends on TMUI being reachable on the external VLAN, which is exposure we do not
want. Reworked to the shadow-VS pattern proven on an earlier build (bigip-apm-cert-ldap
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

## (11) TMUI session-pinning must be OFF for proxied portal sessions
The GUI "Require A Consistent Inbound IP For the Entire Web Session" = sys db
`httpd.matchclient`; the related PAM check is sys httpd `auth-pam-validate-ip`. bigipa's
portal engine SNAT-automaps its fetch to TMUI (source alternates across the internal
self-IPs on parallel connections), so with either check ON, TMUI drops the SSO'd session
mid-flight. Both set to off/false on BOTH units (2026-07-27) + config saved. Serial curl
never trips this; a browser's parallel connections do — verify in a real browser.

## (13) Authorization moved APM → BIG-IP remote-role (operator request)
Requirement: any valid cert identity reaches the webtop/TMUI; the BIG-IP decides the role
(bigip-admins → admin, everyone else → read-only). Changes:
- APM aaa-ldap filter `(&(uid=..)(memberOf=..))` → identity-only `(uid=%{session.custom.cn})`.
- BIG-IP `auth remote-user default-role` no-access → **guest** (read-only) on BOTH units
  (device-local; not synced) + saved. `remote-role warden_admins` (employeeType=warden-admins →
  administrator) unchanged. This IS group-based authz: bigip-admins members carry the
  employeeType stamp on their ou=users access account — no check-roles-group/group-dn needed.
- New non-admin access account uid=bob.user,ou=users (NO employeeType) + OpenBao static role.
Verified via bigipb /var/log/secure pam_bigip_authz: alice → role 0 (Administrator),
bob → level=Guest. NOTE: F5 Guest role is DENIED iControl REST by design (REST probe = 401)
— that is not a failure; Guest gets read-only TMUI. Test the role via the pam_audit
"level=" log line, not a REST call.

## (14) External self-IP lockdown (deviation-12 follow-up, DONE)
With portal delivery now via internal-VLAN shadow façades, nothing needs TMUI/SSH on the
external VLAN. Set `allow-service` to none (empty list via REST — the string "none" is
rejected; PATCH `{"allowService":[]}`) on external-self and ext_float, BOTH units + saved.
Verified: TMUI+SSH now closed on 10.2.10.5/.6/.7; internal portal path (10.2.20.6) still
200. HA is unaffected (configsync/mirror/unicast all live on the internal VLAN).

## (15) revoke-all.sh — real 21.1 teardown mechanisms (un-stubbed)
- APM session cut: there is NO clean `/mgmt/tm/apm/access-session` REST route on 21.1;
  the working verb is `sessiondump --delete <key>` (or `--delete all`) via util/bash.
  `sessiondump --list` enumerates keys; the script discovers a CN's key(s) by grepping
  session vars. `tmsh show apm access-session` does NOT exist on 21.1.
- Credential cut: static-role flow rotates (`ldap/rotate-role/<CN>`); ephemeral flow revokes
  the lease. A calling wrapper around `scripts/revoke-all.sh` can fetch BIGIP_PASS via AppRole and pipe it
  over ssh stdin. GOTCHA: revoke-all sources .env (BIGIP_PASS empty there by design) — it
  preserves an injected BIGIP_PASS across the source, same guard as the APM build.

## (16) OpenBao dev → production (persisted, sealed, auto-unseal)
Swapped `server -dev` (in-memory, lost on recreate) for raft integrated storage via
`docker-compose.prod.yml` + `openbao/openbao-prod.hcl`. Gotchas: this OpenBao 2.x build
DROPPED `disable_mlock` (any value = fatal config error — omit it); a fresh raft/log volume
is root-owned but the image runs as uid 100 (crash: "vault.db: permission denied") so the
volumes are chowned 100:1000 (codified in openbao-init-unseal.sh); compose merges env, so
BAO_DEV_* must be blanked in the override, not omitted. Seal lifecycle: init 1/1, keys +
root token in openbao/.openbao-keys.json (0600, gitignored), .env BAO_TOKEN auto-updated.
AUTO-unseal custody: deploy/openbao-unseal.service (systemd, enabled) unseals ~15s post-boot.
Persistence VERIFIED (container restart preserved the static roles). Full runbook +
rollback in docs/operations/runbooks/openbao-cutover.md. Listener stays HTTP on the internal VLAN (TLS = tracked
follow-on — it cascades into the APM iRule sideband + scoped-token flow).
