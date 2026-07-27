# Production OpenBao config (replaces `server -dev`). Integrated raft storage = state
# PERSISTS across container restart AND recreate (the dev mode's fatal flaw). Started with
# `server -config=/pua/openbao-prod.hcl`; OpenBao boots SEALED and must be unsealed
# (scripts/openbao-init-unseal.sh) before it serves.
#
# Listener stays HTTP on the trusted internal VLAN (10.2.20.0/24) so the APM iRule sideband,
# mint-apm-token.sh, and every bao() helper keep working unchanged. TLS on 8200 is a
# deliberate follow-on (it cascades into the iRule + scoped-token flow) — tracked separately.

ui = true
# NOTE: this OpenBao 2.x build DROPPED support for `disable_mlock` — setting it (any value)
# is a fatal config error. mlock is no longer used; protect secrets by disabling/encrypting
# host swap instead. Do not re-add a disable_mlock line.

storage "raft" {
  path    = "/openbao/data"     # persisted volume (see docker-compose.prod.yml)
  node_id = "pua-openbao-1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"          # internal VLAN only; TLS = tracked follow-on
}

api_addr     = "http://10.2.20.30:8200"
cluster_addr = "http://10.2.20.30:8201"

# 2.x requires audit devices declared in config (unchanged from dev overlay).
audit "file" {
  type = "file"
  path = "file/"
  options = {
    file_path = "/openbao/logs/openbao-audit.log"
  }
}
