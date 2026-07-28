#!/usr/bin/env bash
# T1.6 — issue a BIG-IP credential. Output goes to STDOUT ONLY; never redirect this
# into a file, log, or commit message.
#
# The credential model is set by PUA_CRED_MODE in .env (see ADR 0006):
#   ephemeral (default) — a throwaway leased account; no argument needed.
#   static              — rotates a standing account; pass the principal (CN):
#                           scripts/issue-cred.sh alice.admin
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# an explicit inline PUA_CRED_MODE=… override wins over the .env default (preserve across source)
_MODE_IN="${PUA_CRED_MODE:-}"
set -a; . "${HERE}/../.env"; set +a
[ -n "$_MODE_IN" ] && PUA_CRED_MODE="$_MODE_IN"
# shellcheck source=lib/cred.sh
. "${HERE}/lib/cred.sh"

cred_issue "${1:-}"
