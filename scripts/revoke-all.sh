#!/usr/bin/env bash
# T2.1/T2.3 — one-shot "end this session everywhere":
#   1. future logins   -> OpenBao lease revoke (deletes the ephemeral LDAP entry)
#   2. TMUI (APM)       -> delete the APM session (STUBBED until T2.3 confirms syntax on 21.1.0)
#   3. SSH (Guacamole)  -> kill the active Guacamole tunnel
#
# Usage: revoke-all.sh <lease_id> [apm_session_id] [guac_connection_id]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
LEASE_ID="${1:?usage: revoke-all.sh <lease_id> [apm_sid] [guac_conn_id]}"
APM_SID="${2:-}"
GUAC_CONN="${3:-}"

bao() { docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN}" openbao bao "$@"; }

echo "== 1. revoke OpenBao lease (future logins) =="
bao lease revoke "$LEASE_ID" && echo "  ok: lease revoked, LDAP entry deleted"

echo "== 2. delete APM session (TMUI cut) =="
if [ -n "$APM_SID" ]; then
  : "${BIGIP_PASS:?export BIGIP_PASS to reach bigipa REST}"
  # ⚠ VALIDATE endpoint on 21.1.0 in T2.3, then remove this guard.
  # Expected: DELETE /mgmt/tm/access/session/<sid>  (or `tmsh delete apm session <sid>`)
  curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" -X DELETE \
    "https://${BIGIP_MGMT}/mgmt/tm/access/session/${APM_SID}" -w '  HTTP %{http_code}\n' || true
else
  echo "  (skipped — no apm_session_id given; STUB: confirm delete verb in T2.3)"
fi

echo "== 3. kill Guacamole tunnel (SSH cut) =="
if [ -n "$GUAC_CONN" ] && [ -n "${GUAC_ADMIN_TOKEN:-}" ]; then
  # ⚠ needs a Guacamole admin token (GET /api/tokens) + the active connection id.
  curl -s -X DELETE \
    "http://${LAB_HOST_IP}:8080/guacamole/api/session/data/postgresql/activeConnections/${GUAC_CONN}?token=${GUAC_ADMIN_TOKEN}" \
    -w '  HTTP %{http_code}\n' || true
else
  echo "  (skipped — need GUAC_ADMIN_TOKEN + guac_connection_id; wire in T2.3/T1.8)"
fi

echo "== done =="
