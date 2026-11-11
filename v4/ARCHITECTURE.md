# Galactic Station v4 — Architecture and implementation status

## Design goal

Replace the legacy 16-core/eight-pair cluster and fragmented installers with four maxed Tier 3 OpenComputers servers. Each server runs one resident \`gsd\` service. That service owns one modem port and one \`event.pull\` loop. Network request dispatch, witness leases, local logging and life-support sampling are handled by that service rather than a collection of independently polling scripts.

## Four-server topology

| ID | Role | Responsibilities |
|---|---|---|
| GS-CORE-01 | Preferred primary core | Requests active authority; reports health; hosts the future primary station-services workload |
| GS-CORE-02 | Standby core | Requests authority only when the primary is unavailable; reports health; future failover target |
| GS-HUB-01 | Witness / admin / archive | Independent lease witness, central management console, GitHub gateway, encrypted remote administration, central log archive |
| GS-LIFE-01 | Main Service | Local read-only equipment sampler and life-support alarms |

The two core computers form one redundant pair, not eight specialized pairs. The Hub is the third arbiter. If the Hub is unavailable, the core pair stops renewing authority and the active core demotes itself when its local lease expires. The life-support sampler is independent of core authority.

### Honest implementation boundary

The v4.0.0 foundation implements encrypted messaging, node discovery, remote file operations, staged GitHub updates, node heartbeats, witness lease arbitration, central log forwarding, and read-only Main Service equipment sampling.

It does **not yet** implement application-level state replication between GS-CORE-01 and GS-CORE-02, the full station command/business logic, automatic failover of the physical life-support connections, automatic machine actuation, or coordinated multi-server rollback. A lease grant means a core has authority; it does not mean all station applications have already been implemented.

## Hardware profile

Each server is specified by the operator as:
- Tier 3 Server and Tier 3 Processor
- Tier 3 Graphics Card
- Tier 3 Data Card
- Internet Card
- Wired Network Card
- up to three Tier 3 Component Buses
- up to four Tier 3.5 RAM modules
- up to four Tier 3 hard drives

All four machines use the same hardware profile to simplify replacement. GS-HUB-01 is the only machine that needs Internet Card access for routine GitHub synchronization. The other Internet Cards can remain installed but are not used by the runtime.

A Tier 3 Component Bus adds capacity for additional components. The three buses are intended to give GS-LIFE-01 enough local component capacity for adapters and life-support equipment.

## Physical network

The Network Card is a wired OpenComputers network interface. Connect all four server Network Cards to the same cable network. If the four servers are installed in one Server Rack, configure their Network Card nodes to share the same rack side. Keep the server's component-facing connection for local adapters separate from the private server-to-server network side where practical.

The initial runtime uses one dedicated in-game port: **45840**. It does not require a Wireless Network Card.

## Cryptography and trust

The v4.0.1 transport uses the Tier 3 Data Card for SHA-256, AES encryption/decryption, and secure random generation. AES key derivation is truncated to 16 bytes because the Data Card's AES API requires a 128-bit key. Envelopes are encrypted and authenticated with AES plus HMAC-SHA256.

The first bootstrap generates a fresh 32-byte station secret on GS-HUB-01 and saves its hexadecimal representation at \`/etc/galactic/master.key\`. The operator enters the same 64-hex-character secret on the other three servers. This secret must never be committed to GitHub or shown in screenshots.

This first release uses a per-station shared secret. It provides confidentiality and integrity on a trusted in-game network, but a compromised server can expose the shared secret and thereby impersonate another station node. Per-node asymmetric identities and key rotation are planned hardening work.

## Services

- \`gsd.lua\`: one resident daemon on every server. It owns port 45840 and one \`event.pull\` loop.
- \`gs.lua\`: central management console on GS-HUB-01.
- \`gs_life.lua\`: read-only sampler loaded by \`gsd\` on GS-LIFE-01.
- \`gs_crypto.lua\`: Data Card-backed AES/HMAC implementation.
- \`gs_bootstrap.lua\`: single installer for the four roles.

The v4 runtime intentionally avoids separate event-listener callbacks. The daemon's main loop remains alive for the lifetime of the service. The management console runs as a separate foreground process on the Hub.

## Main Service equipment

GS-LIFE-01 is connected to the oxygen sealers, pump, electrolytic separator, gas-burning generator and Elite Energy Cube through its local component network and the necessary adapters/cables.

The initial sampler only calls a fixed allow-list of status and getter methods. It does not call \`setEnabled\`, \`pullFluid\`, \`pushFluid\`, \`suck\`, \`drop\`, inventory transfers, or redstone setters.

The previously inspected electric pump exposed no callable OpenComputers methods. v4 reports it as detected-but-not-readable until an appropriate adapter or interface is installed.

## Logs and storage

Every node maintains a bounded local log at \`/var/galactic/logs/gs.log\`. Non-Hub nodes forward log records to GS-HUB-01, which maintains its central archive at the same path. GS-LIFE-01 also stores the latest equipment snapshot at \`/var/galactic/logs/life_support_latest.dat\`.

The four HDDs are not yet automatically partitioned or configured as RAID. The bootstrap leaves disk layout intact. The first installation should inventory the actual mounted filesystems; a later storage pass will assign log/archive/backup volumes and implement verified file-level replication. Do not describe multiple installed HDDs as RAID until a mirror has actually been configured and tested.

## Remote management and GitHub

Only GS-HUB-01 is the normal management terminal and GitHub gateway. It downloads approved files from the public repository and transfers encrypted chunks over port 45840. Remote agents stage files through temporary paths and preserve a \`.gs4bak\` copy when replacing a file.

Updates are staged; running Lua programs are not hot-reloaded. Restart one server at a time during a maintenance window. The console's \`collect all\` command exports logs, status and Main Service snapshots onto the Hub for review. Operational logs are not automatically uploaded to the public repository.

## Fail-safe behavior

- Core nodes need a current lease from GS-HUB-01 to report active authority.
- GS-HUB-01 grants the preferred primary while it is healthy; standby becomes eligible after the primary's lease expires.
- Loss of witness communication demotes the active core.
- Life-support sampling continues locally when GS-HUB-01 is unavailable.
- The initial life-support code is read-only; it does not switch equipment or move fluids.
