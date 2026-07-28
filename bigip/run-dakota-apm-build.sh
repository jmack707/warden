#!/usr/bin/env bash
# Operator wrapper: fetch bigipa admin pw via the f5-onboard AppRole + mint the scoped
# OpenBao fetch-token from the warden VM, then run the APM build against bigipa.
# Run on Nora:  bash bigip/run-dakota-apm-build.sh
set -euo pipefail
cd /root/1broken.net-lab/bootstrap/f5-bigip
set -a; . ./lab-dakota.env; set +a
source bin/bao.sh; bao_login >/dev/null
BPW=$(bao_field common password)
# scoped OpenBao token for the APM in-session fetch (created on the VM's OpenBao)
APM_TOKEN=$(ssh -o StrictHostKeyChecking=accept-new root@10.2.20.30 \
  'cd /root/warden && ./scripts/mint-apm-token.sh' 2>/dev/null)
[ -n "$APM_TOKEN" ] || { echo "failed to mint APM_TOKEN from the VM" >&2; exit 1; }
cd /root/warden
BIGIP_PASS="$BPW" APM_TOKEN="$APM_TOKEN" ./bigip/phase2-apm-dakota-rest.sh "$@"
