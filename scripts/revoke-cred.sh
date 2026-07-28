#!/usr/bin/env bash
# T1.6 — revoke a credential by its handle (from issue-cred.sh).
# The handle is self-describing (see ADR 0006 / lib/cred.sh):
#   a lease id (contains '/')  -> ephemeral: the account is deleted immediately.
#   a bare principal/CN        -> static: the password is rotated (old one invalidated).
# Usage: revoke-cred.sh <handle>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
# shellcheck source=lib/cred.sh
. "${HERE}/lib/cred.sh"
[ $# -eq 1 ] || { echo "usage: $0 <handle>   (lease id for ephemeral, CN for static)" >&2; exit 2; }

cred_revoke "$1"
