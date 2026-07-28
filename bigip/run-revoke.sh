#!/usr/bin/env bash
# Operator wrapper (run on Nora): fetch the bigipa admin pw via the f5-onboard AppRole,
# then run the Warden kill-switch on the warden VM with BIGIP_PASS injected at runtime.
# The password is piped over ssh stdin (read via $(cat)), so it never lands in argv/ps.
#   Run on Nora:  bash bigip/run-revoke.sh --cn <CN> [--lease <id>] [--apm-key <k>]
set -euo pipefail
cd /root/1broken.net-lab/bootstrap/f5-bigip
set -a; . ./lab-dakota.env; set +a
source bin/bao.sh; bao_login >/dev/null
BPW=$(bao_field common password)
[ -n "$BPW" ] || { echo "failed to fetch bigipa admin pw via AppRole" >&2; exit 1; }
printf '%s' "$BPW" | ssh -o StrictHostKeyChecking=accept-new root@10.2.20.30 \
  "cd /root/warden && BIGIP_PASS=\$(cat) ./scripts/revoke-all.sh $*"
