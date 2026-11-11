# Galactic Station v4 — Fresh Installation

This is the new installation path. Do not use the v3 root-level installers or the old 17-computer instructions.

Repository: https://github.com/JA3297/galactic-station-core
v4 bootstrap: https://raw.githubusercontent.com/JA3297/galactic-station-core/main/v4/gs_bootstrap.lua

## 1. Build four maxed Tier 3 servers

Use four Tier 3 Server components, ideally in one OpenComputers Server Rack. Each server gets the hardware profile below:

| Component | Quantity / tier |
|---|---|
| Server | Tier 3 |
| Processor | Tier 3 |
| Graphics Card | Tier 3 |
| Data Card | Tier 3 |
| Internet Card | 1 |
| Network Card | 1 wired |
| Component Bus | up to 3 × Tier 3 |
| Memory | up to 4 × Tier 3.5 |
| Hard Disk Drive | up to 4 × Tier 3 |

The Data Card is required by v4 cryptography. The wired Network Card is required for communication. The Internet Card on GS-HUB-01 is used for GitHub downloads; the other three servers do not need Internet access for normal operation after installation.

### Server Rack networking

A Server Rack holds up to four Server components. In the rack GUI, configure the Network Card node from each server to share the same rack side. Prefer an internal side that is not connected to outside networks, to keep the station LAN private.

For GS-LIFE-01, connect its server/component-facing side to the adapters and cable network serving the Main Service equipment. Keep the server-to-server Network Card LAN separate where practical.

If you are not using one Server Rack, connect all four wired Network Cards to the same OpenComputers cable network.

## 2. Install OpenOS on persistent storage

Each server must boot from a writable hard drive, not a temporary/read-only floppy.

1. Boot the OpenOS installer floppy.
2. Run \`install\`.
3. Select the floppy as the source and the server's intended hard drive as the target.
4. Finish installation, reboot, and remove the floppy.
5. Confirm the machine boots from its hard drive.

Do not format or wipe the old computers merely to use v4. v4 runs on the four new servers. Keep the old cluster powered off during v4 commissioning so duplicate legacy node IDs cannot transmit on the station network.

## Data Card preflight (important)

The v4.0.1 crypto helper also derives a 16-byte AES key, matching the OpenComputers Data Card AES API requirement.

Before installing GS-HUB-01, verify that the installed card exposes the required API. OpenComputers Tier 2 Data Cards add `encrypt`, `decrypt`, and `random`; Tier 3 adds elliptic-curve methods on top of that Tier 2 functionality. A component can be detected as type `data` while still lacking the methods required by this software.

Run:

```sh
wget -f https://raw.githubusercontent.com/JA3297/galactic-station-core/main/v4/data_card_check.lua /tmp/data_card_check.lua
lua /tmp/data_card_check.lua
```

For v4, the key methods must report AVAILABLE:
- `sha256`
- `encrypt`
- `decrypt`
- `random`

The tests should report SHA-256 PASS, Random PASS, and AES round-trip PASS. A Tier 3 card should additionally report `generateKeyPair`, `deserializeKey`, `ecdh`, and `ecdsa` as available.

If one of the required methods is missing, stop here and send the diagnostic output. Do not substitute a time/address-derived key or continue the installation. Check the actual card tier and that it is installed in a compatible card slot and exposed to the server's component network.

## 3. Install GS-HUB-01 first

Use the server that will become the command, witness, and logging hub.

Download the bootstrap:

\`\`\`sh
wget -f https://raw.githubusercontent.com/JA3297/galactic-station-core/main/v4/gs_bootstrap.lua /tmp/gs_bootstrap.lua
lua /tmp/gs_bootstrap.lua
\`\`\`

Choose:

\`\`\`text
3 = GS-HUB-01 (witness, management, logs, GitHub)
\`\`\`

The installer generates a fresh 32-byte station secret with the Tier 3 Data Card and saves it locally at:

\`\`\`text
/etc/galactic/master.key
\`\`\`

It prints the 64-character hexadecimal secret once. Copy it privately. Do not screenshot it, post it, or send it to ChatGPT. This key is shared by the four v4 servers; anyone who reads it on one server can impersonate another node, so keep local files and the in-game network restricted to trusted operators.

The Hub installs:
- \`gsd.lua\`: resident daemon
- \`gs_crypto.lua\`: Data Card-backed AES/HMAC
- \`gs_life.lua\`: read-only equipment sampler library
- \`gs.lua\`: management console
- \`gs_manifest.lua\`: GitHub update manifest
- \`gs_rc.lua\`: startup service

## 4. Install GS-CORE-01

On the next server, run the same two bootstrap commands and choose:

\`\`\`text
1 = GS-CORE-01 (primary operations)
\`\`\`

When prompted, enter the Hub's 64-character station key twice.

## 5. Install GS-CORE-02

On the third server, run the bootstrap and choose:

\`\`\`text
2 = GS-CORE-02 (standby operations)
\`\`\`

Enter the same key.

## 6. Install GS-LIFE-01

On the server physically connected to the Main Service equipment, run the bootstrap and choose:

\`\`\`text
4 = GS-LIFE-01 (Main Service equipment)
\`\`\`

Enter the same key.

The first life-support release is read-only. It discovers the oxygen sealers, electric pump, electrolytic separator, gas-burning generator, Elite Energy Cube and oxygen pipes, then reads a limited allow-list of status/telemetry methods. It will not turn equipment on/off or transfer fluids.

The known electric pump interface did not expose callable methods in the previous inventory. v4 will report it as detected-but-not-readable until its adapter/control interface is identified.

## 7. Start the services

Complete installation on all four servers before starting any daemon.

Start **GS-HUB-01 first**:

\`\`\`sh
rc gs start
rc gs enable
\`\`\`

The witness has a 10-second boot guard. Wait at least 12 seconds.

Start **GS-CORE-01**:

\`\`\`sh
rc gs start
rc gs enable
\`\`\`

Start **GS-CORE-02**:

\`\`\`sh
rc gs start
rc gs enable
\`\`\`

Start **GS-LIFE-01**:

\`\`\`sh
rc gs start
rc gs enable
\`\`\`

Each computer runs exactly one v4 daemon. Do not start the old \`station\`, \`witness\`, \`remote_admin\`, \`module_agent\`, or v3 Main Service monitor on these four machines.

## 8. Verify cryptography and launch the console

On GS-HUB-01:

\`\`\`sh
lua /usr/bin/gs_crypto_test.lua
\`\`\`

Expected:

\`\`\`text
AES encrypt/decrypt: PASS
All tests passed.
\`\`\`

Then launch:

\`\`\`sh
lua /usr/bin/gs.lua
\`\`\`

## 9. Initial commissioning commands

At the GS v4 console:

\`\`\`text
discover
nodes
hub
\`\`\`

Expected topology: three remote nodes discovered (GS-CORE-01, GS-CORE-02, GS-LIFE-01) plus the local GS-HUB-01 management host.

Check the preferred primary:

\`\`\`text
use GS-CORE-01
info
\`\`\`

Check the standby:

\`\`\`text
use GS-CORE-02
info
\`\`\`

Check Main Service:

\`\`\`text
use GS-LIFE-01
info
life
\`\`\`

The two core nodes should report one ACTIVE lease holder and one STANDBY node after the witness boot guard and lease exchange. The Main Service snapshot should show equipment and getter readings. The pump may show \`DETECTED_NO_READABLE_API\`.

## 10. Remote file management and logs

Examples:

\`\`\`text
discover
use GS-CORE-01
ls /
ls /var/galactic
cat /var/galactic/logs/gs.log
get /usr/bin/gsd.lua /home/gsd-core01.lua
put /home/maintenance.lua /home/maintenance.lua
mkdir /home/maintenance
logs 40
collect all
\`\`\`

\`collect all\` saves diagnostic bundles on GS-HUB-01 under:

\`\`\`text
/home/galactic-diagnostics/GS-CORE-01/
/home/galactic-diagnostics/GS-CORE-02/
/home/galactic-diagnostics/GS-LIFE-01/
\`\`\`

GS-HUB-01's own log is already local at \`/var/galactic/logs/gs.log\`.

## 11. GitHub updates

The Hub has the Internet Card and downloads the v4 manifest from GitHub. The other servers receive updates over the encrypted wired network:

\`\`\`text
update GS-CORE-02
\`\`\`

Updates are staged with a \`.gs4bak\` backup. They do not hot-reload running code. Update the standby first, verify it, then restart one node at a time. Never restart both core nodes together. Update GS-HUB-01 locally through the bootstrap/download procedure; the remote console does not administer its own daemon as a remote node.

## 12. What v4.0.0 does not claim yet

- No application-state replication between core nodes yet; current failover is lease/authority failover.
- No automatic transfer of GS-LIFE-01's physical component connections to a core server.
- No automatic life-support equipment actuation or fluid transfer.
- No automatic RAID setup or guaranteed replication across all four HDDs.
- No per-node cryptographic identities yet; the initial network uses a shared station key.
- No automatic coordinated fleet rollback.

Those are later engineering phases. v4.0.0 is the clean, smaller supervisory/management foundation on which we can build them.
