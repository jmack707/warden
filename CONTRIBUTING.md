# Contributing

The rules below exist because breaking them has bitten us.

## Secrets
- Never commit `.env`, private keys (`certs/*.key`, `certs/clients/*`), issued passwords, or
  `openbao/.openbao-keys.json`. All are gitignored — keep them that way.
- For the demo, `BIGIP_PASS` sits in `.env`. In production, leave it empty and inject it
  from your secret manager at runtime — the wrappers preserve an injected value across the
  `.env` source, so a real password never has to be written to disk.

## Changes to the BIG-IP
- Builds are idempotent and teardown-first; re-run `./bigip/run-apm-build.sh` rather than
  hand-patch.
- `./deploy.sh` orchestrates the whole flow; individual scripts are safe to run on their own.
- `admin`/`root` and the local auth source are never modified — they are the recovery path.

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
