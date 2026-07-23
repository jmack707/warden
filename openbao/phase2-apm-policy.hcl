# T2.2 — least-privilege policy for the APM credential-fetch path.
# The gateway token may ONLY read the ephemeral-admin creds endpoint. It must NOT be
# able to read ldap/config (bind creds), rotate roots, or touch sys/*.
path "ldap/creds/pua-admin" {
  capabilities = ["read"]
}
