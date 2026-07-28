#!/usr/bin/env bash
# Build the APM front door against the target BIG-IP(s) defined in .env.
# Reads BIGIP_PASS from .env (demo) or from the environment if injected (production:
# export BIGIP_PASS from your secret manager and leave it blank in .env).
#   ./bigip/run-apm-build.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
_PASS_IN="${BIGIP_PASS:-}"
set -a; . "${HERE}/../.env"; set +a
[ -n "$_PASS_IN" ] && BIGIP_PASS="$_PASS_IN"
: "${BIGIP_PASS:?set BIGIP_PASS in .env (or export it) — the target BIG-IP admin password}"

# Mint the scoped OpenBao token the APM in-session fetch uses (least-priv: warden-apm-read).
APM_TOKEN="$("${HERE}/../scripts/mint-apm-token.sh")"
[ -n "$APM_TOKEN" ] || { echo "failed to mint the scoped OpenBao token (is OpenBao up + configured?)" >&2; exit 1; }

BIGIP_PASS="$BIGIP_PASS" APM_TOKEN="$APM_TOKEN" "${HERE}/apm-build.sh" "$@"
