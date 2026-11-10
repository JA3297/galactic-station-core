> **Current management expansion:** authenticated remote administration, GitHub-driven deployment, and mirrored log collection are documented in [REMOTE_ADMIN_AND_LOGGING.md](REMOTE_ADMIN_AND_LOGGING.md). This is a management overlay on the existing station network, not an SSH implementation: it provides HMAC-authenticated modem messaging, a restricted remote command set, file transfer, staged updates, and mirrored archives. The management traffic is not encrypted.

# Galactic Station Core — OpenComputers

A starter supervisory-computing package for a Galacticraft/OpenComputers station. It runs the 16 service-module core computers as eight redundant pairs, plus one independent cluster witness. All sixteen core computers use the same runtime and receive different configuration files.

**Target:** OpenComputers with OpenOS and its classic Lua 5.2 APIs (`component`, `computer`, `event`, `filesystem`, `serialization`). This has not been tested against every modpack fork or OpenComputers Rebooted; API differences may require small adjustments.

## Download contents

- `station.lua` — shared runtime for all 16 core computers.
- `witness.lua` — independent lease arbiter for the eight redundant pairs.
- `configs/server_A1.lua` through `configs/server_A8.lua` — Rack A configurations.
- `configs/server_B1.lua` through `configs/server_B8.lua` — Rack B configurations.
- `configs/witness.lua` — witness configuration and pair membership.
- `station_api.lua` — API for local module controllers to publish telemetry/events and request/receive commands.
- `module_agent.lua` — optional module communications/diagnostic process; it does not operate hardware.
- `station_rc.lua`, `witness_rc.lua` — optional OpenOS `rc` startup wrappers.
- `examples/` — sample safety rules, access-control list, module identity, and quick-start.

## Core computer assignment

| Pair | Rack A | Rack B | Role and hosted services |
|---|---|---|---|
| Command | CORE-A1 | CORE-B1 | Command routing, coordination, registry |
| Network | CORE-A2 | CORE-B2 | Network monitoring and communications service hooks |
| Telemetry | CORE-A3 | CORE-B3 | Telemetry aggregation, node health |
| Data | CORE-A4 | CORE-B4 | Event archive, records, replica/backup |
| Safety | CORE-A5 | CORE-B5 | Telemetry limit evaluation, alarms, emergency broadcast |
| Utilities | CORE-A6 | CORE-B6 | Resource tracking, utility/power coordination, scheduling hooks |
| Operations | CORE-A7 | CORE-B7 | Station-status responses, maintenance/event visibility |
| Security | CORE-A8 | CORE-B8 | Operator allow-list, configuration/software/time service hooks |

Rack A is the preferred active side. Rack B is synchronized/standby and becomes active when the witness grants it a lease. Both members receive the station broadcasts and independently maintain their local state.

The configuration files are intentionally separate. For example, `server_A3.lua` must be installed only on CORE-A3, and `server_B3.lua` only on CORE-B3.

## Network layout

The runtime uses OpenComputers modem broadcasts on port **45821**. Every core computer, witness, and module computer must use the same `network_id`, which defaults to `GALACTIC-STATION-01`.

For better path redundancy, use two independent OpenComputers network paths and attach two modems to each important computer where the modpack/hardware supports that arrangement. The code broadcasts through every modem attached to a computer. The two paths should not share the same single cable, switch, or intermediary. A dual-modem computer on one shared network is not meaningful path redundancy.

The network ID is a traffic-separation label, not encryption or authentication. Do not connect an untrusted computer to the station network.

## Installation

1. Install OpenOS on all 17 computers (16 core computers and one witness). A tier 2 or better computer with enough RAM and a writable filesystem is recommended for each core server; the archive and telemetry nodes benefit from more storage.
2. Connect modems and verify the computers can communicate over the same OpenComputers network. Use wired modems for fixed station infrastructure where possible.
3. On each of the 16 core computers, create `/etc/station` and `/var/station` if they do not already exist. Copy `station.lua` to `/usr/bin/station.lua`.
4. Copy exactly one matching file from `configs/` to `/etc/station/node.lua`. For example, CORE-A1 receives `configs/server_A1.lua`; CORE-B1 receives `configs/server_B1.lua`.
5. Copy `examples/safety_rules.lua` to `/etc/station/safety_rules.lua` on both CORE-A5 and CORE-B5. Edit the rules to match the telemetry fields your local computers publish.
6. Copy `examples/acl.lua` to `/etc/station/acl.lua` on both CORE-A8 and CORE-B8. Edit the operator list. The two security computers should have identical ACL files.
7. On the witness computer, copy `witness.lua` to `/usr/bin/witness.lua` and `configs/witness.lua` to `/etc/station/witness.lua`.
8. Start the witness first by running `witness`. Then start all 16 core nodes by running `station`. The witness waits through its 10-second boot guard before assigning leases.
9. Verify that each pair has exactly one `ACTIVE` member and one `STANDBY` member. CORE-A1 through CORE-A8 are preferred at initial election; rack B should remain standby while rack A is healthy.

The OpenComputers `component`, modem, event, and serialization APIs are documented in the [OpenComputers component access guide](https://ocdoc.cil.li/component:component_access), [modem component guide](https://ocdoc.cil.li/component:modem), [event API](https://ocdoc.cil.li/api:event), and [serialization API](https://ocdoc.cil.li/api:serialization).

## Automatic startup (optional)

Copy `station_rc.lua` to `/etc/rc.d/station.lua` on each core computer, then run:

```text
rc station enable
```

Copy `witness_rc.lua` to `/etc/rc.d/witness.lua` on the witness and run:

```text
rc witness enable
```

Reboot and verify the processes. The `rc` wrappers run the long-lived programs in detached OpenOS threads. For initial commissioning, start the programs manually so startup errors are visible.


## Remote administration and centralized logging

The repository now includes an optional management plane:

- `station_admin.lua` — interactive management console for discovery, node selection, remote directory listing, file reads/downloads/uploads, directory creation, rename/delete, safe diagnostics, confirmed reboot, GitHub staging, and log tailing.
- `remote_admin_agent.lua` and `remote_admin_rc.lua` — per-computer authenticated remote filesystem/diagnostic agent.
- `admin_crypto.lua` — Lua SHA-256/HMAC-SHA256 implementation and self-test.
- `remote_admin_setup.lua` — one-time bootstrap for managed computers.
- `deploy/manifest.lua` — role-aware source-to-destination manifest used by the management console's GitHub update command.
- `station_logger.lua` — local rotating spool and authenticated log broadcaster.
- `station_log_collector.lua` — independent log collectors for CORE-A4 and CORE-B4.
- `REMOTE_ADMIN_AND_LOGGING.md` — complete setup, operation, security caveats, and test plan.

Management and log traffic use ports 45822 and 45823, separate from the existing station protocol on 45821. The management plane uses a shared secret kept only in each computer's `/etc/station/remote_admin.key`; never commit this file or paste it into public logs. HMAC authenticates and protects message integrity, but does not encrypt packets. Keep the modem network trusted. The remote command set is intentionally allow-listed rather than arbitrary remote shell/Lua execution.

CORE-A4 and CORE-B4 each maintain an independent copy of received logs. This is application-level mirrored storage, **not hardware RAID**. The manager can retrieve logs with `logs` or `get`; it does not automatically publish operational logs to this public repository.

See [REMOTE_ADMIN_AND_LOGGING.md](REMOTE_ADMIN_AND_LOGGING.md) before enabling this feature on the full station. Start with two test nodes, verify key consistency, discovery, read/write transfers, and mirrored logs, then roll out gradually.

## Module-local integration

The service module does not directly control individual module equipment. Each module keeps its own local computers and uses `station_api.lua` only to exchange status/requests with the central network.

1. Copy `station_api.lua` to `/usr/lib/station_api.lua` on a module computer.
2. Copy `examples/module.lua` to `/etc/station/module.lua` and set a unique `module_id` (for example `HABITATION-01`).
3. In a local controller, use:

```lua
local station = require("station_api")

-- Field name should be stable and should match any configured safety rule.
station.telemetry("cabin_temperature", 21.5, "C")
station.telemetry("reserve_fraction", 0.82, "fraction", "reserve_fraction")
station.event("maintenance_due", "NOTICE", "Inspection interval reached")
```

`station.telemetry(field, value, unit, resource)` publishes a measurement. The optional `resource` value feeds the station-wide resource tracker. The values must be serializable Lua primitives (numbers, strings, booleans, or nil); do not send functions, component proxies, or cyclic tables.

`station.event(name, severity, detail)` records an event. Publishing severity `EMERGENCY` causes the active emergency coordinator to broadcast a station emergency notification.

### Command authorization flow

The basic command flow is deliberately explicit:

1. A local user interface calls `station.requestAccess(operator, permission, target, request_id)`.
2. The module program waits for a matching `access_response` packet. Only the active security server issues the response.
3. If approved, the module calls `station.command(operator, request_id, approval_id, target_module_id, action, args)`.
4. The active command server consumes the one-use approval and broadcasts `command_dispatch`.
5. The target module-local controller validates the request against its own interlocks, current state, and local policy. Only then may it carry out the requested action.

The sample `module_agent.lua` prints commands addressed to its module but **does not execute them**. It is a communications test harness, not an equipment controller.

**Security limitation:** the sample ACL is an application allow-list, not cryptographic authentication. The `operator` string travels over the station network and can be spoofed by a malicious or compromised station computer. Treat the OpenComputers network as trusted and do not use this starter implementation as a real security boundary. A later revision should add authenticated operator sessions and message authentication if the modpack provides suitable cryptographic facilities.

## Failover behavior

- Each core member sends a lease request to `STATION-WITNESS` every two seconds.
- The witness grants a short lease to one node in each pair. Rack A is preferred when both candidates are present.
- The active node demotes itself when its lease expires. It does not continue issuing central commands without renewed authority.
- The witness waits for the previous lease window to expire before granting the other member. A brief supervisory-service interruption is expected during takeover.
- State is periodically saved locally. CORE-A4 replicates a compact archive snapshot to CORE-B4. Other pairs process the same telemetry/event broadcasts, allowing their standby members to maintain their own state.
- If a pair loses both computers, only that pair's central service is lost. Module-local computers continue their own operations.

### Important witness limitation

This first implementation uses **one independent witness computer** to avoid split-brain operation. That witness is therefore a single point of *automatic failover arbitration*, although it is not a single point of control for the module-local systems. If the witness fails, existing active servers relinquish their leases after a few seconds and the core supervisory layer becomes unavailable until the witness returns. Local controllers continue autonomously. Do not run two copies of `witness.lua` simultaneously; this simple protocol is not a multi-witness consensus system.

For commissioning, the single-witness design is safer than an uncoordinated automatic promotion. A future high-availability revision should use a proper three-voter quorum or a separately engineered redundant witness protocol rather than simply duplicating the witness script.

## What is implemented now, and what remains an extension point

Implemented in this starter package:

- Pair identities, heartbeat discovery, active/standby state, lease-based failover.
- Node registry and missing-node health checks.
- Telemetry collection and latest-value resource tracking.
- Configurable telemetry limit rules and station alarm broadcasts.
- Emergency event broadcast.
- Event logging, local state persistence, and compact archive-pair replication.
- Basic operator allow-list and one-use command approval/dispatch flow.
- Terminal status display and station-time beacon/offset estimate.
- Module API and a non-actuating sample agent.

Intentionally left as extension points:

- Detailed utility/power dispatch algorithms and scheduling policy.
- External communications gateway integration.
- A graphical multi-screen crew interface.
- Role-aware GitHub staging over the authenticated management plane is now implemented in the optional remote-admin overlay. Per-file backups are retained as `.gsa-backup`; coordinated package rollback and automatic rolling restarts remain future work.
- Hardware-specific redstone, adapter, Galacticraft, or other mod integration.
- Cryptographic operator authentication and multi-witness quorum consensus.

The central computers are supervisory. Do not remove local interlocks or make safety-critical equipment depend solely on a remote central command.
