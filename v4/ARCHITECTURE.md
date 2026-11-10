# Galactic Station v4 architecture

## Design goal

Replace the legacy 16-core/eight-pair cluster and its fragmented installers with four maxed Tier 3 OpenComputers servers. Every server runs one resident \`gsd\` service. The service owns one modem event loop and dispatches station, witness, logging, life-support and management messages. This avoids the former collection of separate modem-polling programs and event-listener lifetime problems.

## Four-server topology

| ID | Role | Responsibilities |
|---|---|---|
| GS-CORE-01 | Primary core | Central station state, coordination, active authority, station services |
| GS-CORE-02 | Standby core | State replica, standby processing, failover candidate |
| GS-HUB-01 | Witness / admin / archive | Independent lease witness, central admin console, GitHub gateway, log archive |
| GS-LIFE-01 | Main Service | Local read-only equipment telemetry and life-support alarms |

The two core machines form one redundant pair, not eight specialized pairs. The Hub is the third vote/arbiter. If the Hub is unavailable, the core pair stops renewing authority and both cores fail closed. The life-support computer is a separate local controller and must not depend on core authority to continue basic monitoring.

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

All four machines have the same hardware profile for easy replacement. Only GS-HUB-01 needs Internet Card access for normal GitHub synchronization; other Internet Cards may remain installed but are not used by the runtime.

The wired Network Card communicates over OpenComputers cable networks. The four servers must be joined to the same wired network (or routed network) through their Network Card connections. Wireless cards are not required.

## Network services

The v4 runtime uses one dedicated in-game modem port, 45840. The encrypted packet envelope carries a protocol version, AES initialization vector, ciphertext, and HMAC-SHA256. Each node uses its Tier 3 Data Card for SHA-256, AES, and secure random bytes. The initial bootstrap uses a per-station shared secret, kept locally in \`/etc/galactic/master.key\`; it must never be committed to GitHub or photographed. This gives encrypted/authenticated traffic on the trusted in-game network, but a compromised node can expose the shared secret. Per-node asymmetric identities are a planned hardening stage.

## Services

- \`gsd\`: the only resident daemon. It owns the modem port and runs one \`event.pull\` loop.
- \`gs\`: local management console on GS-HUB-01. It discovers nodes, browses/edits files, collects logs, and stages GitHub updates.
- \`gs_life\`: read-only sampler loaded by \`gsd\` on GS-LIFE-01. It reads only known getter methods and never actuates machines.
- \`gs_crypto\`: Data Card-backed AES/HMAC implementation.
- \`gs_bootstrap\`: the single installer for all four roles.

## Life-support equipment

GS-LIFE-01 is connected to the oxygen sealers, pump, electrolytic separator, gas-burning generator and Elite Energy Cube through its local component network/adapter arrangement. The first deployment is read-only. It reports component identity, available methods, safe getter results, communication faults and threshold warnings. It does not call \`setEnabled\`, \`pullFluid\`, \`pushFluid\`, \`suck\`, \`drop\`, or redstone setters.

The earlier inventory showed that the electric pump component exposed no callable OpenComputers methods. v4 will report it as detected-but-not-readable unless a supported adapter or redstone interface is added.

## Storage and logs

Each server writes a bounded local log. GS-HUB-01 keeps the central archive and can mirror log records to GS-CORE-02. The installer will inventory actual mounted filesystems before assigning archive volumes. Multiple HDDs are not automatically equivalent to RAID; v4 uses explicit file-level replication and backups.

## Remote management and GitHub

Only GS-HUB-01 is the management terminal and GitHub gateway. It downloads approved files from the public repository, checks manifest entries, and sends encrypted chunks over port 45840. Agents stage files into temporary paths, preserve a backup, then rename into place. Updates never hot-reload a running daemon; the operator performs a controlled, one-node-at-a-time restart.

The \`gs collect all\` command exports node identity, status, recent logs, component inventory and life-support snapshots into a local diagnostic bundle for review by the operator or ChatGPT. Operational logs are not automatically pushed to the public repository.

## Fail-safe behavior

- Core nodes require a current witness lease to claim active authority.
- Loss of witness communication demotes the active core.
- Life-support monitoring continues locally if the Hub is unavailable.
- Initial life-support code is read-only; no automatic equipment switching or fluid transfer.
- File update and reboot operations are explicit administrative actions.
