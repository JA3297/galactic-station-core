# Galactic Station v4

**New clean architecture: four maxed Tier 3 OpenComputers servers.**

The old 16-core/eight-pair cluster and fragmented v3 installer are no longer the recommended deployment.

- [Fresh installation guide](INSTALL.md)
- [Architecture and implementation status](ARCHITECTURE.md)
- [Unified bootstrap installer](gs_bootstrap.lua)

## Four servers

| Node | Role |
|---|---|
| GS-CORE-01 | Preferred primary station core |
| GS-CORE-02 | Standby core |
| GS-HUB-01 | Witness, management console, GitHub gateway and log archive |
| GS-LIFE-01 | Main Service read-only equipment sampler |

The four servers communicate over wired Network Cards on a private OpenComputers cable network. The v4 runtime uses the Tier 3 Data Card for AES encryption, HMAC-SHA256 and secure random generation.

## Runtime files

- \`gs_bootstrap.lua\` — installs the correct four-server role.
- \`gsd.lua\` — one resident event-loop daemon per server.
- \`gs.lua\` — remote management console on GS-HUB-01.
- \`gs_life.lua\` — read-only sampler for the Main Service equipment.
- \`gs_crypto.lua\` — Data Card-backed encrypted transport.
- \`gs_manifest.lua\` — role-aware GitHub update manifest.
- \`gs_rc.lua\` — OpenOS startup service.

## Release scope

v4.0.2 implements encrypted messaging, remote file administration, GitHub staging, discovery, witness leases, node heartbeats, central log forwarding and read-only life-support sampling.

It is not yet a complete station automation system. Application-state replication, physical life-support failover, automatic equipment control, per-node identities, coordinated rollback and multi-drive archive replication remain future work. See [ARCHITECTURE.md](ARCHITECTURE.md) for precise boundaries.

Start with [INSTALL.md](INSTALL.md).
