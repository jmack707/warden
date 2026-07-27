#!/usr/bin/env bash
# T1.8 — codify the Guacamole setup: rotate the default guacadmin password and create
# the clientless-SSH connection to bigipa (blank creds => Guacamole prompts the user for
# the ephemeral credential at connect time). Idempotent.
#
# After running: browse http://<LAB_HOST_IP>:8080/guacamole , log in as guacadmin with
# GUAC_ADMIN_PW, open "bigipa (ephemeral SSH)", enter an issued pua-* username/password.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
G="http://127.0.0.1:8080/guacamole"
DS="postgresql"
NEWPW="${GUAC_ADMIN_PW:-PuaGuac2026!}"

# token with whatever password currently works (new first, then default)
tok() { curl -s -X POST "$G/api/tokens" --data-urlencode "username=guacadmin" --data-urlencode "password=$1" | jq -r '.authToken // empty'; }
TOK="$(tok "$NEWPW")"; [ -n "$TOK" ] || TOK="$(tok guacadmin)"
[ -n "$TOK" ] || { echo "cannot authenticate to Guacamole" >&2; exit 1; }

echo "== ensure bigipa SSH connection exists =="
EXIST="$(curl -s "$G/api/session/data/$DS/connections?token=$TOK" | jq -r 'to_entries[].value | select(.name=="bigipa (ephemeral SSH)") | .identifier' | head -1)"
if [ -n "$EXIST" ]; then
  echo "  already present (id $EXIST)"
else
  curl -s -X POST "$G/api/session/data/$DS/connections?token=$TOK" -H "Content-Type: application/json" \
    -d "{\"parentIdentifier\":\"ROOT\",\"name\":\"bigipa (ephemeral SSH)\",\"protocol\":\"ssh\",\"parameters\":{\"hostname\":\"${BIGIP_MGMT}\",\"port\":\"22\",\"username\":\"\",\"password\":\"\",\"font-size\":\"12\",\"color-scheme\":\"gray-black\"},\"attributes\":{\"max-connections\":\"5\",\"max-connections-per-user\":\"2\"}}" \
    | jq '{identifier,name,protocol}'
fi

echo "== rotate guacadmin password (if still default) =="
if tok guacadmin >/dev/null 2>&1 && [ -n "$(tok guacadmin)" ]; then
  code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$G/api/session/data/$DS/users/guacadmin/password?token=$TOK" \
    -H "Content-Type: application/json" -d "{\"oldPassword\":\"guacadmin\",\"newPassword\":\"$NEWPW\"}")
  echo "  password change HTTP $code"
else
  echo "  already rotated (default rejected)"
fi
echo "Done. Portal: http://${LAB_HOST_IP}:8080/guacamole  (guacadmin / \$GUAC_ADMIN_PW)"
