# Contributing

This is a lab build. The rules below exist because breaking them has bitten us.

## Secrets
- Never commit `.env`, private keys (`certs/*.key`, `certs/clients/*`), issued passwords, or
  `openbao/.openbao-keys.json`. All are gitignored — keep them that way.
- The BIG-IP admin password is fetched at runtime via the lab OpenBao f5-onboard AppRole.
  `BIGIP_PASS` in `.env` is intentionally empty; do not populate it.

## Repository topology (important)
The canonical repo lives on the **warden VM** (`/root/warden`). **Nora** holds a mirror
(also `/root/warden`) that the operator wrappers build from. The flow:
```bash
# author + commit on the VM (canonical), then sync the Nora mirror:
git -C /root/warden pull --ff-only      # on Nora
```
`bigip/run-dakota-apm-build.sh` and `bigip/run-revoke.sh` run on Nora and use the mirror —
a VM-only edit that is not committed+pulled will not take effect. This has caused "my change
did nothing" more than once.

## Changes to the BIG-IP
- Builds are idempotent and teardown-first; re-run rather than hand-patch.
- Live auth/network mutations may be blocked by the harness auto-mode guard — run them
  through the Nora operator wrapper, or an operator applies the printed command.
- `admin`/`root` and the local auth source are never modified.

## Documentation
Docs follow the repository documentation standard (`doc-standard.json`, service preset). The
rules that matter:
- One page, one job. The README orients and points; it is not the manual.
<!-- doclint:ignore DOC004 -- this line names the forbidden markers to document the rule -->
- No `TODO`/`TBD`/`FIXME`/unfilled placeholders — fill from the code or delete the section.
- Every procedure ends with a verification step; every runbook ends with rollback +
  escalation. Version-pin what you tested (`Last validated: YYYY-MM`).
- Record decisions as ADRs in `docs/adr/` (one per file, immutable once accepted);
  record per-change lab specifics in `DEVIATIONS.md`.

## Before you push
```bash
scripts/validate-phase1.sh      # GATE 1A must stay green
```
If you changed the BIG-IP path, re-run the relevant gate/verification in
[docs/deploy.md](docs/deploy.md) and note the result in [CHANGELOG.md](CHANGELOG.md).
