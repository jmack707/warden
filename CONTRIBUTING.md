# Contributing

The rules below exist because breaking them has bitten us.

## Development setup
You need a Linux host with `docker` and the Compose **v2 plugin** — every script and runbook
invokes it as `docker compose`, and the standalone v1 binary is end-of-life
(Debian/Ubuntu: `sudo apt-get install -y docker-compose-v2`). Also install `openssl`,
`ldap-utils`, `jq`, and `gettext-base` (for `envsubst`); `python3` is used by several scripts
to parse JSON. Then:

```bash
cp .env.example .env      # fill in the <angle-bracket> values
./deploy.sh --stack       # certs, containers, directory, OpenBao — no BIG-IP needed
```

`./deploy.sh --stack` is enough to develop and test the OSS credential core. The BIG-IP half
(`./deploy.sh --bigip`) needs a reachable BIG-IP with **APM** provisioned and REST access on
`443` — without one you can still change and lint the BIG-IP code, but you cannot claim it
works. Full prerequisites and the step-by-step teaching path are in
[docs/install.md](docs/install.md) and [docs/manual-build.md](docs/manual-build.md).

### Secrets
- Never commit `.env`, private keys (`certs/*.key`, `clients/*.key`/`.p12`), issued passwords, or
  `openbao/.openbao-keys.json`. All are gitignored — keep them that way.
- For the demo, `BIGIP_PASS` sits in `.env`. In production, leave it empty and inject it
  from your secret manager at runtime — the wrappers preserve an injected value across the
  `.env` source, so a real password never has to be written to disk.

### Changes to the BIG-IP
- Builds are idempotent and teardown-first; re-run `./bigip/run-apm-build.sh` rather than
  hand-patch.
- `./deploy.sh` orchestrates the whole flow; individual scripts are safe to run on their own.
- `admin`/`root` and the local auth source are never modified — they are the recovery path.

## Testing
There is no unit-test suite; the gates are end-to-end scripts that prove the real flow.
Run what your change touches, and say in the PR which ones you ran:

```bash
./scripts/validate-phase1.sh        # GATE 1A — issue → directory entry → LDAPS bind → revoke; no BIG-IP
scripts/preflight-directory.sh      # read-only: proves an external AD/LDAP is usable, writes nothing
./teardown.sh --all --dry-run       # prints exactly what a teardown WOULD remove
python3 .github/scripts/doc_lint.py # the documentation standard, same check CI runs
```

GATE 1A must stay green for any change to the credential core. If you changed the BIG-IP
path, also re-run the relevant gate — `scripts/gate1b-verify.sh` for BIG-IP auth (needs
`BIGIP_PASS` in the environment and `sshpass`) — plus the verification matrix in
[docs/deploy.md](docs/deploy.md#verification), and record the result in
[CHANGELOG.md](CHANGELOG.md). The browser click-through in
[docs/operations/runbooks/browser-verify.md](docs/operations/runbooks/browser-verify.md) is the
only way to prove the webtop SSO path; `curl` cannot.

## Documentation
Docs follow the repository documentation standard (`doc-standard.json`, service preset). The
rules that matter:
- One page, one job. The README orients and points; it is not the manual.
- No placeholder or stand-in text left behind — fill the section from the code or delete it.
  The linter fails the build on the usual stand-in markers, so an unfilled page cannot merge.
  Angle-bracket values for site-specific input (`<bigip-mgmt-ip>`) are the required style and
  are not flagged.
- Every procedure ends with a verification step; every runbook ends with rollback +
  escalation. Version-pin what you tested (`Last validated: YYYY-MM`).
- Record decisions as ADRs in `docs/adr/` (one per file, immutable once accepted);
  record per-change lab specifics in [DEVIATIONS.md](DEVIATIONS.md).
- A change that adds a setting, a script, a flag, or an endpoint updates the matching page
  under `docs/reference/` in the same commit — the linter compares them and fails on drift.

The check runs on every pull request via `.github/workflows/docs-lint.yml`, using the linter
vendored at `.github/scripts/doc_lint.py` so it works offline and cannot break because an
upstream moved. Run it locally before you push:

```bash
python3 .github/scripts/doc_lint.py
```

## Pull requests
- Branch off `main`, one concern per PR. Keep the diff to the thing you are changing —
  generated material (`certs/`, `clients/`, `.env`) never belongs in it.
- Before you push: run the gates above for what you touched, and `python3
  .github/scripts/doc_lint.py` must exit 0.
- In the description, state what you changed, which gate/verification you ran and its result,
  and the versions you ran it against (TMOS, OpenBao, OpenLDAP). "Untested against a BIG-IP"
  is an acceptable answer; silence is not.
- Behaviour changes get a [CHANGELOG.md](CHANGELOG.md) entry; design decisions get an ADR in
  `docs/adr/`; lab-specific deviations go in [DEVIATIONS.md](DEVIATIONS.md).
