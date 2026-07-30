# Bring your own directory (AD / FreeIPA / LDAP)

By default Warden runs its own OpenLDAP and seeds three demo principals — good for a
first look, useless for showing the flow against *your* users. Set
`WARDEN_DIRECTORY_MODE=external` and Warden uses your directory instead, creating nothing
in it.

_Last validated: 2026-07 — bundled and external (OpenLDAP) on Debian 13; the AD notes are
schema-derived, not yet lab-verified against a DC._

## What Warden needs from a directory
Two separate things. Keep them separate when you point Warden at your own:

| | Env | Access | What Warden does |
|---|---|---|---|
| **Identities** | `WARDEN_USER_SEARCH_BASE` | read-only | APM extracts the cert CN and confirms the account exists (`<WARDEN_LOGIN_ATTR>=<CN>`) |
| **Privileged accounts** | `WARDEN_PRIV_SEARCH_BASE` | **password reset** | OpenBao takes over these accounts and rotates their passwords; the BIG-IP binds the injected credential against them |
| **Admin group** | `WARDEN_ADMIN_GROUP_DN` | read-only | Members get Administrator on the BIG-IP; everyone else gets read-only |

The privileged accounts are the sharp edge: **OpenBao will change their passwords**, on a
schedule and on every session. Point `WARDEN_PRIV_SEARCH_BASE` at a dedicated OU of
purpose-made accounts. Never at your general user population, and never at accounts a human
logs in with directly.

The client-cert PKI stays Warden's own either way — the CA in `certs/` signs the client
certs and the APM front door trusts it. Your directory supplies identity and authorization,
not the cert trust anchor.

## Defining the BIG-IP admin group
This is one variable:

```bash
WARDEN_ADMIN_GROUP_DN=cn=BigipAdmins,ou=Groups,dc=example,dc=com
```

The BIG-IP evaluates `WARDEN_ADMIN_ROLE_ATTRIBUTE` — an `<attribute>=<value>` pair — against
the authenticated user, and grants `administrator` on a match. Its default depends on mode:

| Mode | Default mapping | Why |
|---|---|---|
| bundled | `employeeType=warden-admins` | the stamp Warden seeds on the demo accounts |
| external | `memberOf=<WARDEN_ADMIN_GROUP_DN>` | real group membership, which your users already have |

Override it when your directory expresses "is an admin" some other way — a custom attribute,
a nested group, `title=...`, whatever the BIG-IP can match:

```bash
WARDEN_ADMIN_ROLE_ATTRIBUTE=memberOf=cn=NetOps,ou=Groups,dc=example,dc=com
```

Everyone who authenticates but does not match stays read-only (`guest`) — that is the
default role Warden sets, and it is deliberate: a cert holder who is not an admin still
reaches the webtop, they just cannot change anything.

### Two traps worth knowing before you pick a mapping
Both of these fail the same way — **everyone silently ends up read-only**, with a successful
login and nothing that looks like an error. `scripts/preflight-directory.sh` checks for both.

**1. The group must contain the accounts the BIG-IP authenticates.** Warden separates
identities (`WARDEN_USER_SEARCH_BASE`, what APM looks up after cert auth) from privileged
accounts (`WARDEN_PRIV_SEARCH_BASE`, what the BIG-IP actually binds with the injected
credential). The remote-role is evaluated against the **bound account** — the privileged
one. Putting your human identity entries in the admin group does nothing; the privileged
accounts must be the members.

**2. The mapping attribute must come back from a default search.** The BIG-IP evaluates
remote-role against the attributes its own search returns, and it does not ask for extra
attributes by name. Any attribute the directory only returns *on request* is invisible to
it:

| Directory | `memberOf` | Usable for remote-role? |
|---|---|---|
| Active Directory | real, stored attribute | yes — the external default works as-is |
| OpenLDAP + `slapo-memberof` | **operational** (returned only when requested) | **no** — verified in-lab: mapping silently degraded every user to guest |
| 389DS / FreeIPA | plugin-written attribute, but subject to ACIs | run the pre-flight — it tests exactly what the BIG-IP sees |

Where `memberOf` is unusable, map on a real attribute your privileged accounts carry:

```bash
WARDEN_ADMIN_ROLE_ATTRIBUTE=employeeType=warden-admins   # what bundled mode uses
```

The group DN still matters for documentation and for your own provisioning; the BIG-IP just
decides on the attribute.

## Setup
### 1. Prepare the directory (you do this, once)
- A **read-only service account** for searches → `WARDEN_BIND_DN` / `BIND_PW`.
- An account that may **reset passwords** on the privileged OU → `WARDEN_DIR_ADMIN_DN` /
  `WARDEN_DIR_ADMIN_PW`. Delegate exactly that, nothing more.
- A **dedicated OU** for privileged accounts, one per operator who needs BIG-IP admin
  (`WARDEN_PRIV_SEARCH_BASE`).
- The **admin group**, with the right operators in it.
- **LDAPS** working, and the issuing CA exported to a PEM (`WARDEN_LDAP_CA_FILE`). The
  BIG-IP validates the chain and fails closed if it cannot.

### 2. Fill in `.env`
```bash
WARDEN_DIRECTORY_MODE=external
WARDEN_LDAP_HOST=dc01.example.com
WARDEN_LDAP_SCHEMA=ad                  # or openldap (FreeIPA, 389DS, OpenLDAP)
WARDEN_LDAP_CA_FILE=/etc/ssl/certs/example-root-ca.pem
BASE_DN=dc=example,dc=com
WARDEN_BIND_DN=cn=svc-bigip-bind,ou=Service,dc=example,dc=com
BIND_PW=...
WARDEN_USER_SEARCH_BASE=ou=Users,dc=example,dc=com
WARDEN_PRIV_SEARCH_BASE=ou=PAM,dc=example,dc=com
WARDEN_DIR_ADMIN_DN=cn=svc-warden-rotate,ou=Service,dc=example,dc=com
WARDEN_DIR_ADMIN_PW=...
WARDEN_ADMIN_GROUP_DN=cn=BigipAdmins,ou=Groups,dc=example,dc=com
WARDEN_PRINCIPALS="alice.admin bob.user"     # who gets a client cert + a static role
```

### 3. Pre-flight, then deploy
```bash
scripts/preflight-directory.sh    # read-only: LDAPS chain, both binds, group, subtrees
./deploy.sh                       # runs the pre-flight itself and refuses to continue if it fails
```
The pre-flight writes nothing. It reports the exact `.env` key behind each failure, and
confirms that `memberOf` is actually searchable before the BIG-IP depends on it.

## Active Directory specifics
- `WARDEN_LDAP_SCHEMA=ad` switches OpenBao to reset `unicodePwd` and defaults
  `WARDEN_LOGIN_ATTR=sAMAccountName`.
- AD DNs are `CN=<display name>,OU=...` while login is `sAMAccountName`. Warden builds
  privileged-account DNs as `<WARDEN_PRIV_DN_ATTR>=<CN>,<WARDEN_PRIV_SEARCH_BASE>`, with
  `WARDEN_PRIV_DN_ATTR=cn` under the `ad` schema — so the names you pass in
  `WARDEN_PRINCIPALS` must match the DN's `CN` component. Where they differ, create the PAM
  accounts with `CN` equal to `sAMAccountName` (simplest), or pass explicit DNs to
  `scripts/configure-openbao-static.sh`.
- Password resets over LDAP require LDAPS on the DC — plain 389 will refuse.
- `memberOf` on AD is computed and searchable, so the default group mapping works as-is.
  Nested groups are NOT expanded by the BIG-IP remote-role: make operators direct members.

## FreeIPA / 389DS
Use `WARDEN_LDAP_SCHEMA=openldap` with `WARDEN_LOGIN_ATTR=uid`. FreeIPA computes `memberOf`,
so the default mapping works. Its default subtrees are
`cn=users,cn=accounts,<BASE_DN>` and `cn=groups,cn=accounts,<BASE_DN>` — set
`WARDEN_USER_SEARCH_BASE` and `WARDEN_ADMIN_GROUP_DN` accordingly.

## Credential model interaction
`WARDEN_CRED_MODE=ephemeral` has OpenBao *create* throwaway accounts, which means it must
stamp the admin attribute on them — impossible with `memberOf` (directories compute it, they
do not accept it as an input). So:

| Mapping | `static` | `ephemeral` |
|---|---|---|
| attribute (`employeeType=...`) | works | works — Warden stamps it on creation |
| group (`memberOf=...`) | works | **no** — use static, or map on an attribute instead |

`static` is the APM injection path and the default, so this only bites if you deliberately
switch the operator/issue path to ephemeral against a group mapping.

## Removing it
`./teardown.sh` never deletes anything in an external directory — Warden created nothing
there. It does drop the OpenBao static roles, which leaves your privileged accounts holding
passwords nobody knows; reset them yourself afterwards. See
[upgrade.md](upgrade.md#teardown).
