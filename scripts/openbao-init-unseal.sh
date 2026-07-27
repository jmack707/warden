#!/usr/bin/env bash
# Production OpenBao seal lifecycle. Idempotent — safe to run on every boot:
#   * uninitialized -> `operator init`, persist unseal keys + root token to a root-only
#                      file (openbao/.openbao-keys.json, 0600, gitignored), unseal, and
#                      write the new root token into .env (BAO_TOKEN).
#   * sealed        -> unseal using the stored keys.
#   * unsealed      -> no-op.
#
# Key custody (operator choice — see OPENBAO-PROD.md):
#   AUTO  : keep .openbao-keys.json on the VM; wire this script to run at boot (compose
#           healthcheck / systemd unit) so the stack self-unseals after a reboot.
#   MANUAL: after init, copy the keys OFF the VM, delete .openbao-keys.json, and run this
#           script by hand (pasting keys) after each restart. Most secure; no unattended boot.
#
# Shares/threshold default 1/1 for lab auto-unseal; override with SHARES/THRESHOLD env.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENVF="${HERE}/../.env"
KEYS="${HERE}/../openbao/.openbao-keys.json"
SHARES="${SHARES:-1}"; THRESHOLD="${THRESHOLD:-1}"
bao(){ docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 openbao bao "$@"; }

# The openbao image runs as uid 100 / gid 1000; a freshly-created raft/log volume is
# root-owned, so the server crash-loops on "vault.db: permission denied". Fix perms up
# front (idempotent — a no-op once owned). Named per the compose project prefix.
for vol in pua-oss_openbaodata pua-oss_openbaologs; do
  docker volume inspect "$vol" >/dev/null 2>&1 && \
    docker run --rm -v "${vol}:/v" busybox chown -R 100:1000 /v >/dev/null 2>&1 || true
done

status_json(){ bao status -format=json 2>/dev/null || true; }
initialized(){ echo "$1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("initialized",False))' 2>/dev/null; }
sealed(){ echo "$1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("sealed",True))' 2>/dev/null; }

S="$(status_json)"
if [ "$(initialized "$S")" != "True" ]; then
  echo "== OpenBao uninitialized -> operator init (${SHARES} shares / ${THRESHOLD} threshold) =="
  OUT="$(bao operator init -key-shares="$SHARES" -key-threshold="$THRESHOLD" -format=json)"
  umask 077; printf '%s' "$OUT" > "$KEYS"; chmod 600 "$KEYS"
  echo "  keys + root token saved to openbao/.openbao-keys.json (0600, gitignored)"
  RT="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["root_token"])' < "$KEYS")"
  # update .env BAO_TOKEN in place (root-only, gitignored)
  if grep -q '^BAO_TOKEN=' "$ENVF"; then
    sed -i "s|^BAO_TOKEN=.*|BAO_TOKEN=${RT}|" "$ENVF"
  else
    printf 'BAO_TOKEN=%s\n' "$RT" >> "$ENVF"
  fi
  echo "  .env BAO_TOKEN updated to the generated root token"
  S="$(status_json)"
fi

if [ "$(sealed "$S")" = "True" ]; then
  [ -f "$KEYS" ] || { echo "SEALED but no key file — paste keys manually: 'docker exec -it openbao bao operator unseal'"; exit 1; }
  echo "== sealed -> unsealing =="
  python3 -c 'import sys,json;[print(k) for k in json.load(open(sys.argv[1]))["unseal_keys_b64"]]' "$KEYS" \
    | head -n "$THRESHOLD" | while read -r k; do bao operator unseal "$k" >/dev/null; done
  echo "  unsealed"
else
  echo "== already unsealed — nothing to do =="
fi
bao status -format=json | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  status:",{k:d.get(k) for k in ("initialized","sealed")})'
