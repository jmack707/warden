# Dev-mode overlay: OpenBao 2.x requires audit devices to be declared in config
# (no longer enableable via API/CLI). Mounted read-only at /warden/openbao.hcl and
# loaded with `server -dev -config=/warden/openbao.hcl`. Storage/listener/root-token
# still come from -dev.
audit "file" {
  type = "file"
  path = "file/"
  options = {
    file_path = "/openbao/logs/openbao-audit.log"
  }
}
