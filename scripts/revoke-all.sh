#!/usr/bin/env bash
# T2.3 — one-shot "end this PUA session everywhere". Three independent cuts, each
# best-effort (a failure in one still attempts the others):
#   1. Future logins  -> OpenBao: rotate the static role (APM flow) AND/OR revoke a lease
#                        (ephemeral Phase-1 flow). Either invalidates the injected password.
#   2. TMUI (APM)     -> sessiondump --delete <key> on bigipa (the ONLY working verb on
#                        21.1.0 — there is no clean /mgmt/tm/apm/access-session REST route;
#                        run via util/bash). By --apm-key, or discovered from --cn.
#   3. SSH (Guacamole)-> Guac 1.6 kills an active connection with a PATCH remove-op on
#                        .../activeConnections (NOT DELETE). By --guac-id, or by username==CN.
#
# Usage:
#   revoke-all.sh --cn <CN> [--lease <lease_id>] [--apm-key <key>] [--guac-id <uuid>]
#   revoke-all.sh <lease_id> [apm_key] [guac_id]          # legacy positional (lease-first)
#
# Needs .env: BAO_TOKEN, BIGIP_MGMT/USER/PASS, LAB_HOST_IP, GUAC_ADMIN_PW. Runs on the VM.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a

CN=""; LEASE_ID=""; APM_KEY=""; GUAC_ID=""
if [[ "${1:-}" == --* ]]; then
  while [ $# -gt 0 ]; do case "$1" in
    --cn) CN="$2"; shift 2;;
    --lease) LEASE_ID="$2"; shift 2;;
    --apm-key) APM_KEY="$2"; shift 2;;
    --guac-id) GUAC_ID="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac; done
else                                   # legacy positional
  LEASE_ID="${1:-}"; APM_KEY="${2:-}"; GUAC_ID="${3:-}"
fi
[ -n "$CN$LEASE_ID" ] || { echo "usage: revoke-all.sh --cn <CN> [--lease <id>] [--apm-key <key>] [--guac-id <uuid>]" >&2; exit 2; }

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

echo "== 3. Guacamole: kill the active SSH tunnel =="
GTOK=$(curl -s -X POST "http://${LAB_HOST_IP}:8080/guacamole/api/tokens" \
        --data-urlencode "username=guacadmin" --data-urlencode "password=${GUAC_ADMIN_PW}" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("authToken",""))')
if [ -z "$GTOK" ]; then
  echo "  WARN: could not obtain a Guacamole admin token — skipping"
else
  DS=postgresql
  # collect active-connection UUIDs to remove: explicit --guac-id, else those whose user==CN
  MAPJSON=$(curl -s "http://${LAB_HOST_IP}:8080/guacamole/api/session/data/${DS}/activeConnections?token=${GTOK}")
  IDS=$(python3 - "$MAPJSON" "$GUAC_ID" "$CN" <<'PY'
import sys,json
data=json.loads(sys.argv[1] or "{}"); want_id=sys.argv[2]; cn=sys.argv[3]
out=[]
for uuid,info in data.items():
    if want_id and uuid==want_id: out.append(uuid)
    elif not want_id and cn and info.get("username")==cn: out.append(uuid)
print("\n".join(out))
PY
)
  if [ -z "$IDS" ]; then
    echo "  no matching active connection (pass --guac-id <uuid> to force one)"
  else
    PATCH=$(python3 -c 'import json,sys;print(json.dumps([{"op":"remove","path":"/"+u} for u in sys.argv[1:]]))' $IDS)
    code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H 'Content-Type: application/json' \
      "http://${LAB_HOST_IP}:8080/guacamole/api/session/data/${DS}/activeConnections?token=${GTOK}" -d "$PATCH")
    echo "  killed: $(echo "$IDS" | tr '\n' ' ') (HTTP $code)"
  fi
  curl -s -X DELETE "http://${LAB_HOST_IP}:8080/guacamole/api/tokens/${GTOK}" -o /dev/null
fi

echo "== done =="
