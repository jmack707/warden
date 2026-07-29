#!/usr/bin/env bash
# Renew the scoped OpenBao token the APM fetch iRule uses. mint-apm-token.sh creates it
# with period=768h (32 days); a periodic token DIES if not renewed within its period, and
# the failure mode is silent — the webtop still loads, but SSO injects an empty password
# ("Could not find SSO password" in /var/log/apm). Run this daily from cron on the warden
# host:   0 4 * * * /opt/warden/scripts/renew-apm-token.sh >> /var/log/warden-renew.log 2>&1
#
# Reads the live token from the BIG-IP datagroup (the source of truth the iRule uses),
# then renews it against BAO_ADDR. Exits non-zero if either step fails.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
: "${BIGIP_MGMT:?set BIGIP_MGMT in .env}"; : "${BIGIP_USER:?}"; : "${BIGIP_PASS:?}"
: "${BAO_ADDR:?set BAO_ADDR in .env}"

TOK=$(curl -sk -m 15 -u "${BIGIP_USER}:${BIGIP_PASS}" \
  "https://${BIGIP_MGMT}/mgmt/tm/ltm/data-group/internal/warden_openbao_dg" \
  | jq -r '.records[]? | select(.name=="token") | .data')
[ -n "$TOK" ] && [ "$TOK" != null ] \
  || { echo "$(date -Is) no token in warden_openbao_dg on ${BIGIP_MGMT}" >&2; exit 1; }

RESP=$(curl -s -m 15 -X POST -H "X-Vault-Token: ${TOK}" "${BAO_ADDR}/v1/auth/token/renew-self")
TTL=$(printf '%s' "$RESP" | jq -r '.auth.lease_duration // empty')
[ -n "$TTL" ] \
  || { echo "$(date -Is) renew-self failed: $(printf '%s' "$RESP" | jq -c '.errors // .')" >&2; exit 1; }

echo "$(date -Is) renewed APM token (datagroup on ${BIGIP_MGMT}): ttl ${TTL}s"
