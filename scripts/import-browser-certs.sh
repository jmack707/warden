#!/usr/bin/env bash
# Import the PUA test client certs (alice/bob/carol) into the local browser cert
# stores so you can present them to the APM front door at https://10.2.20.50.
# Run on your workstation (vegas), NOT as root. Needs libnss3-tools (pk12util/certutil):
#   Debian/Ubuntu:  sudo apt-get install -y libnss3-tools
#
# What it does: pulls the .p12 bundles + CA from the pua-oss VM, then imports each into
# every Firefox profile and the Chrome/Chromium NSS DB it finds.
set -euo pipefail

VM="${PUA_VM:-root@10.2.20.30}"                 # pua-oss VM (override with PUA_VM=...)
REMOTE_DIR="/root/pua-oss/certs"
P12_PASS="${PUA_P12_PASS:-pua}"
USERS=(alice.admin bob.user carol.expired)
WORK="${HOME}/.pua-certs"

command -v pk12util >/dev/null || { echo "pk12util not found -> sudo apt-get install -y libnss3-tools" >&2; exit 1; }

echo "==> fetching bundles from ${VM}"
mkdir -p "$WORK"
for u in "${USERS[@]}"; do scp -q "${VM}:${REMOTE_DIR}/clients/${u}.p12" "$WORK/"; done
scp -q "${VM}:${REMOTE_DIR}/ca.crt" "$WORK/pua-ca.crt"

# collect NSS databases: Chrome/Chromium + every Firefox profile (incl. snap/flatpak)
dbs=()
[ -d "$HOME/.pki/nssdb" ] || { mkdir -p "$HOME/.pki/nssdb"; certutil -N --empty-password -d "sql:$HOME/.pki/nssdb" 2>/dev/null || true; }
dbs+=("sql:$HOME/.pki/nssdb")
for base in "$HOME/.mozilla/firefox" "$HOME/snap/firefox/common/.mozilla/firefox" \
            "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"; do
  [ -d "$base" ] || continue
  while IFS= read -r prof; do
    [ -f "$prof/cert9.db" ] && dbs+=("sql:$prof")
  done < <(find "$base" -maxdepth 1 -type d -name '*.*')
done

[ ${#dbs[@]} -gt 0 ] || { echo "no NSS cert stores found (open Firefox/Chrome once to create a profile)"; exit 1; }

echo "==> importing into ${#dbs[@]} cert store(s)"
for db in "${dbs[@]}"; do
  echo "  - $db"
  certutil -A -n "PUA Lab CA" -t "CT,C,C" -i "$WORK/pua-ca.crt" -d "$db" 2>/dev/null || true
  for u in "${USERS[@]}"; do
    pk12util -i "$WORK/${u}.p12" -d "$db" -W "$P12_PASS" >/dev/null 2>&1 \
      && echo "      imported $u" || echo "      (skip $u — already present?)"
  done
done

echo
echo "Done. In the browser, go to https://10.2.20.50 and pick a cert when prompted:"
echo "  PUA alice.admin   -> reaches the webtop (in bigip-admins)"
echo "  PUA bob.user      -> Access Denied (not in bigip-admins)"
echo "  PUA carol.expired -> TLS/cert error (expired) — browser may not even offer it"
echo "Tip: restart the browser after import; pick 'always ask' so you can switch identities."
