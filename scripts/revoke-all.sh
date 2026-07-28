#!/usr/bin/env bash
# One-shot "end this session everywhere". Two independent cuts, each best-effort
# (a failure in one still attempts the other):
#   1. Future logins  -> OpenBao: rotate the static role (injection flow) AND/OR revoke a
#                        lease (ephemeral flow). Either invalidates the credential.
#   2. TMUI (APM)     -> sessiondump --delete <key> on the target (the ONLY working verb on
#                        21.x — there is no clean /mgmt/tm/apm/access-session REST route;
#                        run via util/bash). By --apm-key, or discovered from --cn.
#
# NOTE on SSH: cutting an already-established SSH session is the SSH gateway's job, not this
# script's. Lease revoke / rotation ends FUTURE logins; an open sshd session on the target
# persists until it re-auths or the operator kills it on the box.
#
# Usage:
#   revoke-all.sh --cn <CN> [--lease <lease_id>] [--apm-key <key>]
#   revoke-all.sh <lease_id> [apm_key]                    # legacy positional (lease-first)
#
# Needs .env: BAO_TOKEN, BIGIP_MGMT/USER/PASS. Runs where OpenBao + the target are reachable.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# preserve a runtime-injected BIGIP_PASS (the Nora wrapper pipes it in) across the .env
# source — .env ships BIGIP_PASS empty on purpose (the admin secret isn't stored on the VM).
_PASS_IN="${BIGIP_PASS:-}"
set -a; . "${HERE}/../.env"; set +a
[ -n "$_PASS_IN" ] && BIGIP_PASS="$_PASS_IN"

CN=""; LEASE_ID=""; APM_KEY=""
if [[ "${1:-}" == --* ]]; then
  while [ $# -gt 0 ]; do case "$1" in
    --cn) CN="$2"; shift 2;;
    --lease) LEASE_ID="$2"; shift 2;;
    --apm-key) APM_KEY="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac; done
else                                   # legacy positional
  LEASE_ID="${1:-}"; APM_KEY="${2:-}"
fi
[ -n "$CN$LEASE_ID" ] || { echo "usage: revoke-all.sh --cn <CN> [--lease <id>] [--apm-key <key>]" >&2; exit 2; }

bao(){ docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao bao "$@"; }
bigip(){ curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" -X POST -H 'Content-Type: application/json' \
         "https://${BIGIP_MGMT}/mgmt/tm/util/bash" \
         -d "$(python3 -c 'import json,sys;print(json.dumps({"command":"run","utilCmdArgs":"-c \""+sys.argv[1]+"\""}))' "$1")" \
         | python3 -c 'import sys,json;print(json.load(sys.stdin).get("commandResult","").rstrip())'; }

echo "== 1. OpenBao: invalidate the injected credential =="
if [ -n "$LEASE_ID" ]; then
  bao lease revoke "$LEASE_ID" && echo "  ephemeral lease revoked (LDAP entry deleted)" || echo "  WARN: lease revoke failed"
fi
if [ -n "$CN" ]; then
  if bao write -f "ldap/rotate-role/${CN}" >/dev/null 2>&1; then
    echo "  static role ${CN} rotated — the injected password no longer authenticates"
  else
    echo "  (no static role for ${CN}, or rotate failed — skipping)"
  fi
fi

echo "== 2. APM: delete the TMUI session on bigipa (sessiondump) =="
: "${BIGIP_PASS:?export BIGIP_PASS to reach bigipa REST for the APM cut}"
KEYS="$APM_KEY"
if [ -z "$KEYS" ] && [ -n "$CN" ]; then
  # discover session keys whose vars carry this CN (we set sso.token.last.username=CN)
  KEYS=$(bigip "for k in \$(sessiondump --list 2>/dev/null | awk '{print \$1}'); do if sessiondump --key \$k --allkeys 2>/dev/null | grep -qE 'username *= *${CN}\$|custom.cn *= *${CN}\$'; then echo \$k; fi; done")
  [ -n "$KEYS" ] && echo "  matched session key(s) for ${CN}: $KEYS" || echo "  no live APM session found for ${CN}"
fi
for k in $KEYS; do
  out=$(bigip "sessiondump --delete $k >/dev/null 2>&1 && echo deleted $k || echo failed $k")
  echo "  $out"
done
[ -z "$KEYS" ] && echo "  (nothing to delete — pass --apm-key <key> to force a specific session)"

echo "== done =="
