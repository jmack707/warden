# Manual build — Warden, one piece at a time

`./deploy.sh` builds the whole demo in one shot. This document builds the same thing
deliberately, stopping at each layer to say **what it is, why it exists, and how to prove it
works** before moving on. Use it to learn the design, to narrate the demo to an audience, or
to debug a deploy that went sideways — at any point you can stop and hand the rest back to
the scripts.

This is environment-agnostic: any Linux host with Docker plus one BIG-IP with APM.

_Last validated: 2026-07 on Debian 13 (docker.io 26.1.5 / Compose 2.26.1, also verified on
docker-ce 29.6.2 / Compose 5.3.1), OpenBao 2.x, OpenLDAP (osixia) 1.5.0, TMOS 17.5.1._

## The idea, in one paragraph
An operator holds a **client certificate** and nothing else — no password, ever. The BIG-IP's
APM front door authenticates that certificate, extracts the CN, and confirms the person
exists in a directory. It then asks **OpenBao** for the current password of a *separate
privileged account* named for that person, and injects it into the target's TMUI login form.
The operator lands in an administrative session without ever seeing the credential, and
OpenBao rotates it out from under them afterwards. Every component is off-the-shelf: the
credential path contains no custom code, only configuration.

Two ideas do most of the work, and they are worth stating before you build anything:

**Identity and privilege are different objects.** `alice.admin` the *person* lives in the
identity subtree and is what the certificate proves. `alice.admin` the *privileged account*
is a separate directory entry whose password OpenBao owns and rotates. The BIG-IP
authenticates the second one; the certificate proves the first. Keeping them apart is what
lets you revoke privilege without touching identity.

**Authorization lives on the BIG-IP, not in the policy.** APM decides *who may reach the
webtop*; the target BIG-IP decides *what they can do there*, via `remote-role` matching an
attribute on the privileged account. Everyone who authenticates gets read-only by default;
only the admin group is elevated. That split means the access policy stays simple and the
role decision is auditable on the device being administered.

## Prerequisites
- A Linux host with Docker and the Compose v2 plugin (`docker compose`), plus `openssl`,
  `ldap-utils`, `jq`, `gettext-base`.
- One BIG-IP with **APM provisioned and licensed**, reachable from that host on `:443`, and
  able to reach the host on `:389`/`:636` (LDAP/LDAPS) and `:8200` (OpenBao).
- A free IP on a subnet the BIG-IP can serve, for the front-door VIP.
- The repo, and a `.env` copied from `.env.example`.

```bash
cp .env.example .env      # fill in the <angle-bracket> values
set -a; . ./.env; set +a  # every command below assumes these are in your shell
. ./scripts/lib/directory.sh   # resolves the directory layout (subtrees, binds, group)
```

That second `source` matters: the DNs used throughout (`WARDEN_PRIV_SEARCH_BASE`,
`WARDEN_BIND_DN`, `WARDEN_ADMIN_GROUP_DN`…) are *derived* from `.env` rather than hardcoded,
so sourcing the resolver is what makes the commands below copy-pasteable.

---

## Phase 1 — the trust anchor
**What:** a CA, plus a server certificate for the bundled directory.

**Why:** the CA is the root of the whole demo. It signs the client certificates operators
present, and the APM front door is configured to trust exactly this CA — that is what makes
"a valid cert" mean something. It also signs the LDAPS server certificate so the BIG-IP can
validate the directory instead of trusting it blindly.

```bash
./scripts/gen-certs.sh
```

**Verify** the SAN contains the address the BIG-IP will use, or LDAPS validation fails closed
later:

```bash
openssl x509 -in certs/ldap.crt -noout -ext subjectAltName
openssl x509 -in certs/ca.crt  -noout -subject -dates
```

> Re-running is safe: an existing CA is reused. Minting a new one invalidates every issued
> client certificate, so that only happens if you ask (`WARDEN_REGEN_CA=1`).

---

## Phase 2 — the directory
**What:** OpenLDAP in a container, seeded with the two subtrees and a read-only bind account.

**Why:** this is the single source of truth the BIG-IP validates against. The seed creates
`ou=svc` (the read-only account the BIG-IP searches with), and the privileged subtree that
OpenBao will manage. A bind account with read-only rights is deliberate — the device doing
authentication should never hold credentials that can change the directory.

```bash
docker compose --profile bundled up -d
```

The `bundled` profile is what starts OpenLDAP. Without it you get OpenBao only — that is the
"bring your own directory" mode ([directory.md](directory.md)), where this whole phase is
replaced by pointing at your existing AD or LDAP.

Wait for it to answer, then seed. On a fresh volume the container's first-run bootstrap takes
a while, and seeding into a half-initialized server fails in confusing ways:

```bash
. ./scripts/lib/ldif.sh
wait_for_ldap 90
ldif_apply "seed" ldap/seed.ldif
envsubst < ldap/acl-bigip-bind.ldif | docker exec -i openldap ldapmodify -Y EXTERNAL -H ldapi:///
```

**Verify** the structure exists and the read-only account can actually bind:

```bash
ldapsearch -x -LLL -H "ldap://${WARDEN_LDAP_HOST}" -D "${WARDEN_DIR_ADMIN_DN}" \
  -w "${WARDEN_DIR_ADMIN_PW}" -b "${BASE_DN}" dn
ldapwhoami -x -H "ldap://${WARDEN_LDAP_HOST}" -D "${WARDEN_BIND_DN}" -w "${BIND_PW}"
```

---

## Phase 3 — the broker
**What:** OpenBao's LDAP secrets engine, configured to manage accounts in the privileged
subtree.

**Why:** OpenBao is the only thing that knows privileged passwords, and it does not hand them
to humans. Two models are available — see [ADR 0006](adr/0006-configurable-credential-model.md):
*ephemeral* mints a throwaway account per request and deletes it on revoke; *static* takes
over a standing account and rotates its password. The APM injection path uses **static**,
because the target must be able to authorize a known, stable username.

```bash
./scripts/configure-openbao.sh
```

**Verify** the engine can actually drive the directory — this is the first real end-to-end
proof, and it needs no BIG-IP at all:

```bash
./scripts/validate-phase1.sh
```

That mints a credential, confirms the entry appears in LDAP, binds as it over LDAPS, revokes
it, and confirms the entry is gone and the credential rejected. If this is not green, stop
here: nothing downstream can work.

---

## Phase 4 — identities, certificates and privileged accounts
**What:** the demo principals, their client certificates, and the privileged accounts OpenBao
takes over.

**Why:** this is where the identity/privilege split becomes concrete. `gen-test-users.sh`
creates the *identity* entries and issues each a client certificate signed by the Phase 1 CA.
The two LDIFs then create the *privileged accounts* — same names, different subtree — one
stamped with the admin attribute and one deliberately not, so you can demonstrate both
outcomes. `carol.expired` gets a genuinely expired certificate to show the front door
rejecting it at the TLS handshake, before any policy runs.

```bash
./scripts/gen-test-users.sh "${BASE_DN}" seed
for ldif in ldap/warden-users.ldif ldap/remote-roles.ldif; do ldif_apply "${ldif##*/}" "$ldif"; done
./scripts/configure-openbao-static.sh alice.admin bob.user
```

**Verify** OpenBao now owns those passwords — note it reports a length, never a value:

```bash
openssl verify -CAfile certs/ca.crt clients/alice.admin.crt   # carol should FAIL: expired
docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao \
  bao read -format=json ldap/static-cred/alice.admin | jq '{user:.data.username, pwlen:(.data.password|length)}'
```

---

## Phase 5 — the scoped token
**What:** a least-privilege OpenBao token for the BIG-IP to use.

**Why:** the front door has to fetch credentials at session time, which means a token has to
live on the BIG-IP. It must therefore be able to do as little as possible: read
`ldap/static-cred/*` and trigger `ldap/rotate-role/*`, and nothing else. Never put the root
token on a network device.

```bash
./scripts/configure-openbao-phase2.sh          # writes the policy, prints a token
GATE2A=1 ./scripts/configure-openbao-phase2.sh # ...and proves the scope is enforced
```

**Verify** with `GATE2A=1`: it confirms the token *can* read a credential and *cannot* read
`ldap/config` (the bind credentials) or anything under `sys/`. A token that passes this is
safe to store on the BIG-IP.

> The token is periodic and dies if never renewed — `scripts/renew-apm-token.sh` on a daily
> cron is what keeps a long-lived demo working ([deploy.md](deploy.md#keep-the-apm-token-alive)).

---

## Phase 6 — the BIG-IP: authentication and authorization
**What:** `bigip/phase1-target-rest.sh` points the device's system authentication at the
directory over LDAPS and defines who is an administrator.

**Why this is worth understanding rather than typing by hand:** it is only five decisions,
and they are the security model.

| It creates | Why |
|---|---|
| A trust anchor (`warden-ca.crt`) | so LDAPS is *validated*, not merely encrypted |
| `auth ldap system-auth` | the device now authenticates remote users against your directory, searching the **privileged** subtree |
| `remote-user defaultRole guest`, console disabled | everyone who authenticates gets read-only and no shell — the safe default |
| `remote-role warden_admins` | the one rule that grants Administrator, matching `WARDEN_ADMIN_ROLE_ATTRIBUTE` |
| `auth source: ldap` | flips the device over — `admin`/`root` stay **local**, so this cannot lock you out |

```bash
BIGIP_PASS="$BIGIP_PASS" ./bigip/phase1-target-rest.sh
```

**Verify** by logging in as a privileged account and reading the decision from the device
itself — this is the authorization model proving itself, and it is a good thing to show an
audience:

```bash
PW=$(docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao \
     bao read -format=json ldap/static-cred/alice.admin | jq -r .data.password)
printf 'machine %s login alice.admin password %s\n' "$BIGIP_MGMT" "$PW" > /tmp/nr; chmod 600 /tmp/nr
curl -sk --netrc-file /tmp/nr -o /dev/null -w '%{http_code}\n' "https://${BIGIP_MGMT}/mgmt/tm/sys/version"
rm -f /tmp/nr
# on the BIG-IP:  grep pam_bigip_authz /var/log/secure | tail -2
```

`200` and `role 0 (Administrator)` for alice; `bob.user` authenticates too but comes back
`level=Guest` — and `401` on that endpoint, because read-only cannot read it. Both outcomes
are correct.

> **The single most common mistake here** is putting the *identity* entries in the admin
> group. `remote-role` is evaluated against the account the BIG-IP just bound — the
> privileged one. See the traps section in [directory.md](directory.md).

---

## Phase 7 — the BIG-IP: the APM front door
**What:** `bigip/run-apm-build.sh` mints a fresh scoped token and builds the access policy,
the credential fetch, and the delivery objects.

**Why not by hand:** this is roughly thirty API objects including a twelve-item policy graph
committed in one transaction. Typing it teaches you the REST API, not the design. What is
worth knowing is the shape of what it creates:

| Object | Role in the flow |
|---|---|
| `warden-apm-clientssl` | requires a client cert and trusts only the Phase 1 CA — the front door |
| `warden-openldap-aaa` (+ pool) | the identity lookup APM performs after cert auth |
| Access policy `warden-apm` | Cert Auth → extract CN → LDAP query → OpenBao fetch → SSO creds → resource assign → Allow/Deny |
| `warden-apm-openbao-fetch` (iRule) | at session time: rotate this CN's password, read it back, stash it in a session variable |
| `warden_openbao_dg` (data group) | holds the scoped token the iRule presents — never inline in the rule |
| `warden-apm-tmui-sso` (form SSO) | replays username + fetched password into the target's TMUI login form |
| Webtop + Portal Access | what the operator actually sees and clicks |
| Shadow façade VSs (`192.0.2.5/.6`) | APM refuses "reserved" addresses as portal targets, so the real last hop is steered by an iRule ([ADR 0003](adr/0003-shadow-facade-portal-targets.md)) |
| `warden-apm-test-vs` | the VIP operators browse to |

```bash
./bigip/run-apm-build.sh
```

The build is teardown-first, so re-running it is the supported way to apply a change.

**Verify** the full matrix. Run this from a host that reaches the VIP **directly at layer 3** —
mutual TLS does not survive a TLS-terminating proxy, so if your environment fronts services
with an HTTPS proxy, drive the demo from a jump host on the VIP's network instead:

```bash
cd clients
for u in alice.admin bob.user carol.expired; do
  curl -sk --cert $u.crt --key $u.key -o /dev/null -w "$u %{http_code}\n" -L "https://${WARDEN_APM_VIP}/"
done
```

Expected: `alice.admin` and `bob.user` reach the webtop (`200`); `carol.expired` fails at the
handshake (`000`, curl exit 56) — rejected by TLS before the policy is consulted. Then the
browser click-through, which is the only way to exercise the portal rewrite and the SSO form
submit: [operations/runbooks/browser-verify.md](operations/runbooks/browser-verify.md).

---

## When something is wrong
The failures worth recognizing, because each points at a specific layer:

| Symptom | What it actually means |
|---|---|
| websso: `Could not find SSO password for user` | the credential fetch failed — wrong OpenBao address in the iRule, an expired scoped token, or no static role for that CN. Not an SSO problem. |
| Login succeeds but everyone is read-only | `remote-role` never matched. The attribute must be returned by a *default* LDAP search of the privileged account — the BIG-IP does not request attributes by name. |
| `ldap_add: Server is unwilling to perform … no global superior knowledge` | the entry is outside the directory suffix — `BASE_DN` does not match the directory. |
| `LDAP Result Code 32 "No Such Object"` from OpenBao | the privileged account named by the static role does not exist. Usually seeding failed earlier. |
| Cert auth fails after a rebuild | the CA was regenerated and browsers still hold the old client certs. Re-import, or avoid it by not passing `WARDEN_REGEN_CA=1`. |
| A first attempt right after a rebuild denies (`errorcode=19`) | policy-apply lag. Close the browser and retry once. |

## Taking it apart
```bash
./teardown.sh --all --dry-run    # exactly what would be removed, changes nothing
./teardown.sh --all              # BIG-IP config + local stack
./teardown.sh --all --purge      # ...and the volumes, CA and issued certificates
```
Auth source returns to local *before* the LDAP configuration is deleted, and `admin`/`root`
are never touched — see [upgrade.md](upgrade.md#teardown).
