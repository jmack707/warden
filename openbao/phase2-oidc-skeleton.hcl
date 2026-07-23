# T2.2 (optional) — CAC-attributed issuance skeleton. Enables OpenBao to trust JWTs
# minted by APM acting as an OAuth Authorization Server, so each lease is attributed to
# the CAC-derived identity (EDIPI/UPN) in the audit log instead of a shared machine token.
#
# OpenBao side (agent-runnable once APM AS metadata exists):
#   bao auth enable jwt
#   bao write auth/jwt/config \
#     oidc_discovery_url="https://pua-gw.dakota.lab/f5-oauth2/v1/.well-known/openid-configuration" \
#     default_role="pua-apm"
#   bao write auth/jwt/role/pua-apm \
#     role_type="jwt" user_claim="upn" bound_audiences="pua-apm" \
#     policies="pua-apm-read" ttl=15m
#
# APM side [HUMAN, T2.3]: provision the APM OAuth Authorization Server, register
# client_id `pua-apm`, publish the discovery/JWKS endpoints, and have the per-session
# policy present the resulting JWT to OpenBao (login at auth/jwt) BEFORE the creds read,
# so session.custom.pua.baotoken becomes the CAC-attributed token rather than a static one.
