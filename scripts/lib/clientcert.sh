# clientcert.sh — source this. Issues Warden-CA-signed client certs + browser .p12
# bundles. Shared by gen-test-users.sh (bundled demo principals) and gen-client-certs.sh
# (arbitrary principals, e.g. when you bring your own directory).
# Expects: $CERTS (CA dir), $CLIENTS (output dir), $WARDEN_P12_PASS, $WARDEN_DOMAIN.
gen_client() {  # gen_client <uid> <valid|expired>
  local uid="$1" mode="$2"
  openssl req -newkey rsa:2048 -nodes -keyout "$CLIENTS/$uid.key" -out "$CLIENTS/$uid.csr" \
    -subj "/CN=$uid" 2>/dev/null || { echo "ERROR: keygen/CSR failed for $uid" >&2; exit 1; }
  cat > "$CLIENTS/$uid.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectAltName=email:$uid@${WARDEN_DOMAIN:-warden.lab}
EOF
  if [ "$mode" = expired ]; then
    # valid window entirely in the past -> expired now. x509 grew -not_before/-not_after
    # in OpenSSL 3.4; on older builds (Ubuntu 22.04 = 3.0) back-date via `openssl ca`.
    if openssl x509 -help 2>&1 | grep -q not_before; then
      openssl x509 -req -in "$CLIENTS/$uid.csr" -CA "$CERTS/ca.crt" -CAkey "$CERTS/ca.key" -CAcreateserial \
        -not_before 20240101000000Z -not_after 20241231235959Z \
        -extfile "$CLIENTS/$uid.ext" -out "$CLIENTS/$uid.crt"
    else
      local cadir; cadir="$(mktemp -d)"
      touch "$cadir/index.txt"; echo 01 > "$cadir/serial"
      printf '[ca]\ndefault_ca = warden\n[warden]\ndatabase = %s/index.txt\nserial = %s/serial\nnew_certs_dir = %s\ndefault_md = sha256\npolicy = pol\nemail_in_dn = no\n[pol]\ncommonName = supplied\n' \
        "$cadir" "$cadir" "$cadir" > "$cadir/ca.cnf"
      { echo "[ext]"; cat "$CLIENTS/$uid.ext"; } > "$cadir/ext.cnf"
      local caout
      caout="$(openssl ca -batch -config "$cadir/ca.cnf" -keyfile "$CERTS/ca.key" -cert "$CERTS/ca.crt" \
        -startdate 20240101000000Z -enddate 20241231235959Z \
        -in "$CLIENTS/$uid.csr" -extfile "$cadir/ext.cnf" -extensions ext -notext \
        -out "$CLIENTS/$uid.crt" 2>&1)" \
        || { echo "$caout" >&2; echo "ERROR: expired-cert issue failed for $uid" >&2; rm -rf "$cadir"; exit 1; }
      rm -rf "$cadir"
    fi
  else
    openssl x509 -req -in "$CLIENTS/$uid.csr" -CA "$CERTS/ca.crt" -CAkey "$CERTS/ca.key" -CAcreateserial \
      -days 365 -extfile "$CLIENTS/$uid.ext" -out "$CLIENTS/$uid.crt"
  fi
  chmod 0644 "$CLIENTS/$uid.crt"; chmod 0600 "$CLIENTS/$uid.key"
  # PKCS12 bundle for browser import (password: $WARDEN_P12_PASS) — see scripts/import-browser-certs.sh
  openssl pkcs12 -export -inkey "$CLIENTS/$uid.key" -in "$CLIENTS/$uid.crt" \
    -certfile "$CERTS/ca.crt" -name "Warden $uid" -out "$CLIENTS/$uid.p12" \
    -passout pass:"${WARDEN_P12_PASS:-warden}" 2>/dev/null \
    || { echo "ERROR: p12 bundle failed for $uid" >&2; exit 1; }
  chmod 0600 "$CLIENTS/$uid.p12"
}
