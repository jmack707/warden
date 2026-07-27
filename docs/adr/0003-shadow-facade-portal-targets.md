# ADR 0003 — Shadow façade VSs for Portal Access targets

- Status: Accepted
- Date: 2026-07-27
- Supersedes: the external-self-IP target from DEVIATIONS.md (10)

## Context
APM Portal Access refuses to proxy to any address the BIG-IP considers cluster-reserved:
its own self-IPs and virtual-addresses, management IPs, and the device-trust addresses of
every cluster member (configsync/mirror/failover-unicast, per `tmsh list cm device`).
Targeting a peer's internal self-IP (10.2.20.6) produced
`01490585 ... rejected because it points to reserved address` (errorcode=17). No `sys db`
override exists. An interim fix targeted the peer's *external* self-IP, but that requires
TMUI to be reachable on the external VLAN — an exposure we reject.

## Decision
Point Portal Access resources at **non-routable RFC5737 TEST-NET façade IPs** (192.0.2.5,
192.0.2.6), which are not in APM's reserved set. A plain LTM "shadow" virtual server on
each façade (TCP only, TLS passthrough, all VLANs, SNAT automap) steers the last hop with
an iRule `node` command:
- 192.0.2.5 → `node 127.0.0.1 443` (this unit's own TMUI — the active portal unit)
- 192.0.2.6 → `node 10.2.20.6 443` (peer TMUI over the internal VLAN)

A pool cannot hold a self-IP member, so the last hop uses `node`, which needs
`tmm.tcl.rule.node.allow_loopback_addresses=true`. The APM reserved-address check does not
apply to LTM steering, only to Portal Access targets.

## Consequences
- TMUI is never exposed on the external VLAN (see [0003 follow-up in configuration.md];
  external self-IP `allow-service` set to none).
- Both TMUI session-pinning checks (`httpd.matchclient`, `auth-pam-validate-ip`) must be
  off on both units, because the portal engine's SNAT source alternates across the internal
  self-IPs on parallel connections.
- Adding a target = one façade IP + one shadow VS + one iRule + one Portal Access resource;
  the pattern generalizes to any reserved/awkward target.
