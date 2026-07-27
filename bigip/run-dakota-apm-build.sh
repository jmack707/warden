#!/usr/bin/env bash
# Operator wrapper: fetch bigipa admin pw via the f5-onboard AppRole, then run the
# APM decision-core build against bigipa. Run on Nora:  bash bigip/run-dakota-apm-build.sh
set -euo pipefail
cd /root/1broken.net-lab/bootstrap/f5-bigip
set -a; . ./lab-dakota.env; set +a
source bin/bao.sh; bao_login >/dev/null
BPW=$(bao_field common password)
cd /root/pua-oss
BIGIP_PASS="$BPW" ./bigip/phase2-apm-dakota-rest.sh "$@"
