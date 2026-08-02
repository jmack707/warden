# Bring your own directory (AD / FreeIPA / LDAP)

By default Warden runs its own OpenLDAP and seeds three demo principals — good for a
first look, useless for showing the flow against *your* users. Set
`WARDEN_DIRECTORY_MODE=external` and Warden uses your directory instead, creating nothing
in it.

_Last validated: 2026-07 — bundled and external (OpenLDAP) on Debian 13; external (AD)
against a real Windows Server 2025 DC (warden-ad.lab), both credential modes, full
cert→webtop→role matrix._

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
One variable:

```bash
WARDEN_ADMIN_GROUP_DN=cn=BigipAdmins,ou=Groups,dc=example,dc=com
```

Members of that group get `administrator` on the BIG-IP. Everyone else who authenticates
stays read-only (`guest`) — deliberate, so a cert holder who is not an admin still reaches
the webtop and simply cannot change anything.

The BIG-IP does not read groups, though. It evaluates an `<attribute>=<value>` pair against
the account it authenticated, and only sees attributes a **default** LDAP search returns.
Warden bridges group to attribute for you, differently per directory:

| Directory | Bridge |
|---|---|
| Bundled OpenLDAP | `memberOf` is operational there and invisible to the BIG-IP, so Warden stamps the group's members with `employeeType=warden-admins` and maps on that |
| Active Directory | `memberOf` is stored and returned by default; the group is read directly |
| 389DS / FreeIPA | depends on plugin and ACI configuration — the pre-flight tests it |

You only touch `WARDEN_ADMIN_ROLE_ATTRIBUTE` when that bridge cannot work for your
directory, or when "is an admin" is expressed some other way entirely — a custom attribute,
`title=...`, whatever the BIG-IP can match:

```bash
WARDEN_ADMIN_ROLE_ATTRIBUTE=title=network-admin
```

### Two traps worth knowing before you pick a mapping
Both of these fail the same way — **everyone silently ends up read-only**, with a successful
login and nothing that looks like an error. `scripts/preflight-directory.sh` checks for both.

**1. The group must contain the accounts the BIG-IP authenticates.** Warden separates
identities (`WARDEN_USER_SEARCH_BASE`, what APM looks up after cert auth) from privileged
accounts (`WARDEN_PRIV_SEARCH_BASE`, what the BIG-IP actually binds with the injected
credential). The remote-role is evaluated against the **bound account** — the privileged
one. Putting your human identity entries in the admin group does nothing; the privileged
accounts must be the members. Warden's own seed does exactly this, so
[`ldap/admin-group.ldif`](../ldap/admin-group.ldif) is a working example of the shape.

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
- A **read-only service account** for searches → `WARDEN_BIND_DN` / `BIND_PW`. It must be
  able to read the mapping attribute (`memberOf` by default) on the privileged accounts;
  directories that strip attributes for unprivileged binds would otherwise leave everyone
  read-only. The pre-flight checks exactly that.
- An account that may **reset passwords** on the privileged OU → `WARDEN_DIR_ADMIN_DN` /
  `WARDEN_DIR_ADMIN_PW`. It needs two rights, not one: **read/search** on that OU (OpenBao
  looks each account up before rotating it) and **password write**. Reset-only delegation
  survives a naive connectivity check and then fails with OpenBao's opaque *expected one
  matching entry, but received 0*. `WARDEN_CRED_MODE=ephemeral` additionally needs
  **create/delete** of entries there. Nothing beyond that, and nothing outside that OU.
- A **dedicated OU** for privileged accounts, one per operator who needs BIG-IP admin
  (`WARDEN_PRIV_SEARCH_BASE`).
- The **admin group**, with the right operators in it.
- `WARDEN_LDAP_HOST` resolvable **from three places**, because three different things
  connect to your directory: this host (the scripts), the **OpenBao container**, and the
  **BIG-IP**. Containers do not read this host's `/etc/hosts`, and TMOS `dns-resolver`
  cannot read a hosts file either — so a name that only lives in `/etc/hosts` works for
  `ldapsearch` here and fails in both of the others. Set `WARDEN_LDAP_HOST_IP` and Warden
  publishes the name inside the container; point the BIG-IP's DNS at a resolver that knows
  it. Substituting a bare IP only works if the LDAPS certificate carries a matching IP
  SAN, which most do not.
- **LDAPS** working, and the issuing CA exported to a PEM (`WARDEN_LDAP_CA_FILE`). The
  BIG-IP validates the chain and fails closed if it cannot.

### 2. Fill in `.env`
Copy the block for your directory from [Worked examples](#worked-examples) below and adjust
the DNs. Every value is documented in
[reference/configuration.md](reference/configuration.md).

### 3. Pre-flight, then deploy
```bash
scripts/preflight-directory.sh    # read-only: LDAPS chain, both binds, group, subtrees
./deploy.sh                       # runs the pre-flight itself and refuses to continue if it fails
```
The pre-flight writes nothing. It reports the exact `.env` key behind each failure, and
confirms the mapping attribute survives a default search before the BIG-IP depends on it.

The same check runs automatically in **bundled** mode too, near the end of `./deploy.sh`,
against Warden's own seeded directory — so a mapping that would leave everyone read-only is
reported during the deploy rather than discovered at the webtop. In bundled mode it warns and
continues (the data is Warden's own); in external mode it is fatal and stops before the
BIG-IP is touched. Either way it probes as the BIG-IP's read-only bind, which also catches a
directory ACL that hides the attribute from that account.

## Worked examples
Complete, verified against the resolver — each block produces the behaviour described under
it. Only directory settings are shown; `BIGIP_*`, `WARDEN_APM_VIP` and the OpenBao values are
the same as in [.env.example](../.env.example).

### Active Directory
The straightforward case: AD stores `memberOf` and returns it in a default search, so the
group decides directly and the override stays empty.

```bash
WARDEN_DIRECTORY_MODE=external
WARDEN_DOMAIN=corp.example.com          # client-cert email SAN suffix
BASE_DN=DC=corp,DC=example,DC=com

WARDEN_LDAP_HOST=dc01.corp.example.com
WARDEN_LDAP_SCHEMA=ad                   # CN= DNs, unicodePwd resets
WARDEN_LOGIN_ATTR=cn                    # REQUIRED on AD — see the first point below
WARDEN_LDAP_CA_FILE=/etc/ssl/certs/corp-root-ca.pem

WARDEN_BIND_DN=CN=svc-bigip-bind,OU=Service,DC=corp,DC=example,DC=com
BIND_PW=<read-only-bind-pw>
WARDEN_DIR_ADMIN_DN=CN=svc-warden-rotate,OU=Service,DC=corp,DC=example,DC=com
WARDEN_DIR_ADMIN_PW=<reset-rights-pw>

WARDEN_USER_SEARCH_BASE=OU=Staff,DC=corp,DC=example,DC=com
WARDEN_PRIV_SEARCH_BASE=OU=PAM,DC=corp,DC=example,DC=com
WARDEN_ADMIN_GROUP_DN=CN=BigipAdmins,OU=Groups,DC=corp,DC=example,DC=com
WARDEN_ADMIN_ROLE_ATTRIBUTE=            # empty: derived as memberOf=<the group>
WARDEN_PRINCIPALS="alice.admin bob.user"
```

Resolves to login on `cn`, privileged DNs built with `CN=`, the rule
`memberOf=CN=BigipAdmins,…`, OpenBao over `ldaps://dc01.corp.example.com:636`, and no stamp.
_Validated 2026-07 against a Windows Server 2025 DC — both credential modes, full
cert→webtop→role matrix._

Five AD-specific points, all verified against that DC:

- **`WARDEN_LOGIN_ATTR=cn` is required.** The schema default (`sAMAccountName`) cannot
  work with the identity/PAM split this doc prescribes: `sAMAccountName` is unique per
  domain, and the same attribute both matches the cert CN under
  `WARDEN_USER_SEARCH_BASE` and logs the injected credential into the BIG-IP under
  `WARDEN_PRIV_SEARCH_BASE` — the identity account and its PAM twin would need the same
  value, which AD refuses. `cn` is unique only per container: give both accounts
  `CN=<principal>` (the PAM account's own `sAMAccountName` can be anything, e.g.
  `pam-alice.admin`) and both lookups resolve. With the default attribute the BIG-IP
  login fails; with `cn` the matrix passes.
- `CN=BigipAdmins` must contain those **PAM accounts**, not the staff identities.
- **Nested groups are not expanded** by the BIG-IP's remote-role — make operators direct
  members of the group you name.
- Password resets over LDAP **require LDAPS on the domain controller**; plain 389 refuses
  them. That is why `WARDEN_LDAP_CA_FILE` is mandatory in external mode. If the DC's
  LDAPS cert is self-signed (no AD CS), two extra steps or Schannel never serves it: the
  cert must sit in the DC's **Trusted Root** store as well as its Personal store, and be
  loaded via a rootDSE `renewServerCertificate` modify — restarting NTDS does nothing,
  and the failure (TCP accepts, reset at ClientHello) looks like a network problem.
- **Ephemeral mode needs more delegation than static**: the rotate account must also hold
  create/delete child (`user` objects) on the privileged OU — `dsacls <OU>
  /G "<domain>\svc-warden-rotate:CCDC;user"` — on top of Reset Password. Static needs
  only the reset delegation.

### OpenLDAP
The case the override exists for. With the `memberof` overlay, `memberOf` is operational and
invisible to the BIG-IP, so map on a stored attribute and let Warden stamp it.

```bash
WARDEN_DIRECTORY_MODE=external
WARDEN_DOMAIN=example.net
BASE_DN=dc=example,dc=net

WARDEN_LDAP_HOST=ldap.example.net
WARDEN_LDAP_SCHEMA=openldap             # uid login, uid= DNs, userPassword resets
WARDEN_LDAP_CA_FILE=/etc/ssl/certs/example-ca.pem

WARDEN_BIND_DN=cn=bigip-bind,ou=svc,dc=example,dc=net
BIND_PW=<read-only-bind-pw>
WARDEN_DIR_ADMIN_DN=cn=warden-rotate,ou=svc,dc=example,dc=net
WARDEN_DIR_ADMIN_PW=<reset-rights-pw>

WARDEN_USER_SEARCH_BASE=ou=people,dc=example,dc=net
WARDEN_PRIV_SEARCH_BASE=ou=pam,dc=example,dc=net
WARDEN_ADMIN_GROUP_DN=cn=bigip-admins,ou=groups,dc=example,dc=net
WARDEN_ADMIN_ROLE_ATTRIBUTE=employeeType=bigip-admins    # memberOf is invisible here
WARDEN_PRINCIPALS="alice.admin bob.user"
```

Resolves to the rule `employeeType=bigip-admins` and the stamp `employeeType: bigip-admins`.
Keep the group populated as your record of intent, but the attribute is what the BIG-IP acts
on. If your server stores `memberOf` as an ordinary attribute rather than via the overlay,
delete the override and let it derive.

### FreeIPA / 389DS
Start from the OpenLDAP block with these differences. `memberOf` is plugin-written and
returned normally, so the derived rule works — the pre-flight confirms it.

```bash
BASE_DN=dc=lab,dc=example,dc=com
WARDEN_USER_SEARCH_BASE=cn=users,cn=accounts,dc=lab,dc=example,dc=com
WARDEN_ADMIN_GROUP_DN=cn=bigip-admins,cn=groups,cn=accounts,dc=lab,dc=example,dc=com
WARDEN_PRIV_SEARCH_BASE=ou=pam,dc=lab,dc=example,dc=com
WARDEN_ADMIN_ROLE_ATTRIBUTE=
```

_Validated 2026-08 against FreeIPA on Rocky 9 (389DS), credential core in both modes:
pre-flight, static rotation, and ephemeral create→bind→revoke→delete._

FreeIPA's account tree is fixed, so a dedicated privileged subtree either sits outside IPA
management (`ou=pam` at the root, which IPA tooling will not manage) or you accept
privileged accounts living among ordinary ones in `cn=users`. The `ou=pam` shape is the one
validated here, and three things about it are worth knowing:

- **`memberOf` still works there.** The plugin's `memberOfEntryScope` is the whole suffix by
  default, so plain `inetOrgPerson` entries in a subtree IPA does not manage still get
  `memberOf` computed from a `groupOfNames` — the group mapping decides roles exactly as it
  does inside `cn=accounts`.
- **`uid` may repeat across containers**, because FreeIPA ships the `attribute uniqueness`
  plugin **disabled**. So the identity and its privileged twin can share
  `uid=<principal>` in different subtrees, and `WARDEN_LOGIN_ATTR=uid` serves both lookups
  — the collision that forces `WARDEN_LOGIN_ATTR=cn` on AD does not arise. Confirm with
  `ldapsearch -b cn=attribute\ uniqueness,cn=plugins,cn=config` before relying on it.
- **You must add ACIs; the defaults are not enough.** IPA's default ACIs strip attributes
  from unprivileged binds, so the read-only account sees no `memberOf`, and the rotate
  account can bind while seeing nothing under the privileged OU. On the two containers:

  ```
  # on the parent of the subtrees — let the BIG-IP's bind account read entries
  aci: (targetattr="*")(version 3.0; acl "warden-bind read";
       allow (read,search,compare) userdn="ldap:///uid=warden-bind,ou=svc,...";)
  # on the privileged OU — search + password write (add/delete too, for ephemeral)
  aci: (targetattr="*")(version 3.0; acl "warden-rotate read";
       allow (read,search,compare) userdn="ldap:///uid=warden-rotate,ou=svc,...";)
  aci: (targetattr="userPassword")(version 3.0; acl "warden-rotate pw";
       allow (write) userdn="ldap:///uid=warden-rotate,ou=svc,...";)
  aci: (target="ldap:///uid=*,ou=pam,...")(version 3.0; acl "warden-rotate create";
       allow (add,delete) userdn="ldap:///uid=warden-rotate,ou=svc,...";)
  ```

IPA enforces password policy on resets of *its own* accounts, so OpenBao's generated
passwords have to satisfy it or rotation fails. Entries in a raw subtree carry no Kerberos
principal and so are not subject to that policy — one more reason the `ou=pam` shape is the
easier of the two.

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
