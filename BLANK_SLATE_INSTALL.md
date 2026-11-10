# Galactic Station v3 — Blank-Slate Installation Guide

This is the replacement installation procedure for a new or rebuilt OpenComputers station. Use `station_bootstrap.lua`; do not use the older separate installer instructions for a new deployment.

Repository: https://github.com/JA3297/galactic-station-core

## What this installs

The bootstrap installs the correct software and role configuration for:

- 16 core nodes: CORE-A1 through CORE-A8 and CORE-B1 through CORE-B8
- STATION-WITNESS
- Module computers, including MAIN-SERVICE-01
- A standalone management computer, or a management console installed alongside a module

The installed common management plane uses:
- 45821: existing station lease/telemetry protocol
- 45822: authenticated remote administration
- 45823: authenticated log collection

The installer does not format a disk or erase user data. If it replaces an existing file, it first preserves it as a `.pre-gs-backup` file (with a numbered suffix if needed). It creates or replaces only the role-specific Galactic Station files it manages.

## Stage 0 — Install OpenOS persistently

Do this on every computer before installing Galactic Station.

1. Install a hard drive in the computer and insert/boot from the OpenOS floppy.
2. At the OpenOS prompt, run:

   ```sh
   install
   ```

3. Select the OpenOS source disk and the intended hard drive target. Confirm the installation.
4. Reboot when the installer finishes and remove the OpenOS floppy.
5. Boot again from the hard drive.

The OpenOS greeting that says to install to a writable medium is a strong indicator that the computer may still be booting from the floppy. A hard-drive installation is important because files stored on a read-only boot disk or temporary medium will not be a reliable persistent installation.

Reference: OpenComputers' [OpenOS installation guide](https://ocdoc.cil.li/openos) and [install command documentation](https://ocdoc.cil.li/tutorial:program:install).

## Stage 1 — Hardware required

Every managed computer needs:
- OpenOS installed on a writable hard drive;
- at least one modem connected to the same in-game network as the other station computers;
- Internet Card access for this first bootstrap only.

The designated management computer additionally needs Internet access for future GitHub updates.

After installation, the 16 cores, witness, and module computers do not need an Internet Card for normal remote administration. The manager downloads updates from GitHub and transfers them over the in-game modem network.

Do not connect the station modem network to an untrusted network or allow untrusted players access to the computers' local files.

## Stage 2 — Choose the management computer

Recommended layout for the current station:

- Keep the 16 core computers for CORE-A1 through CORE-B8.
- Keep one separate computer as STATION-WITNESS.
- Use the Main Service Module computer as MAIN-SERVICE-01 and also install the management console on it when the bootstrap asks.

This gives you a central console without consuming one of the 17 cluster roles.

The management computer must have a modem, an Internet Card, a writable disk, and a keyboard/screen for the interactive console.

## Stage 3 — Create a new management secret

The previous secret appeared in a screenshot and must not be reused.

Generate a new random secret of at least 64 characters using a password manager. Keep it private. Enter exactly the same secret on the management computer and every managed node when prompted by the bootstrap.

The secret is stored locally at:

```text
/etc/station/remote_admin.key
```

It is never fetched from or committed to GitHub. Do not send it in a screenshot, paste, chat, or public issue.

This first remote-management release uses one shared HMAC key for operational simplicity. HMAC authenticates packets but does not encrypt them. Any computer or person who can read the key can impersonate the management console. Use only on a trusted in-game network. Per-node keys and packet encryption are later hardening work.

## Stage 4 — Install one computer

On the computer being provisioned, run:

```sh
wget -f https://raw.githubusercontent.com/JA3297/galactic-station-core/main/station_bootstrap.lua /tmp/station_bootstrap.lua
lua /tmp/station_bootstrap.lua
```

The bootstrap asks which profile to install:

| Choice | Select on |
|---|---|
| 1 — Core server | Each of the 16 core computers |
| 2 — Cluster witness | The dedicated witness computer |
| 3 — Module computer | The Main Service computer and other module computers |
| 4 — Standalone management console | A computer dedicated only to management |

### Core computers

Select option 1 and enter the exact ID printed below:

| Computer | ID |
|---|---|
| Rack A | A1, A2, A3, A4, A5, A6, A7, A8 |
| Rack B | B1, B2, B3, B4, B5, B6, B7, B8 |

The bootstrap fetches the matching canonical config from `configs/server_<ID>.lua` and installs it as `/etc/station/node.lua`.

It also installs:
- station runtime and startup service;
- remote administration agent and startup service;
- cryptographic library;
- local structured logger;
- A4/B4 archive collector and startup service;
- safety rules on A5/B5;
- ACL on A8/B8.

### Witness

Select option 2. The bootstrap installs:
- witness runtime;
- witness startup service;
- canonical `/etc/station/witness.lua`;
- remote administration and logging support.

### Main Service module

Select option 3 and enter exactly:

```text
MAIN-SERVICE-01
```

The bootstrap installs:
- `/etc/station/module.lua`;
- Station API;
- read-only Main Service monitor and startup service;
- remote administration and logging support.

When asked whether to install the management console on this computer, answer **Y**. This makes MAIN-SERVICE-01 your central management terminal as well as the life-support monitor.

Do not run the optional generic `module_agent` on MAIN-SERVICE-01; the Main Service monitor already publishes its own heartbeat/telemetry and runs its own event loop.

For other modules, provide a unique ID such as `HABITATION-01`. Those get the generic module communications agent.

### Standalone management computer

Select option 4 only when using a separate computer for administration. The bootstrap installs the console, cryptographic test, and key setup utility, and creates `/etc/station/admin.lua` with the chosen network ID.

It does not install a station core, witness, or module runtime on this management-only computer.

## Stage 5 — Start services after all computers are installed

Do not start the core nodes while identities are still being installed. First complete the bootstrap on all 18 computers (16 cores + witness + MAIN-SERVICE-01).

Then start services in this order.

### 5A. Start the two archive collectors

On CORE-A4 and CORE-B4:

```sh
rc remote_admin start
rc remote_admin enable
rc station_log_collector start
rc station_log_collector enable
```

### 5B. Start the witness

On STATION-WITNESS:

```sh
rc remote_admin start
rc remote_admin enable
rc witness start
rc witness enable
```

Wait at least 12 seconds for the witness boot guard.

### 5C. Start Rack A

On each of CORE-A1 through CORE-A8:

```sh
rc remote_admin start
rc remote_admin enable
rc station start
rc station enable
```

### 5D. Start Rack B

On each of CORE-B1 through CORE-B8:

```sh
rc remote_admin start
rc remote_admin enable
rc station start
rc station enable
```

Do not start both sides of a pair with conflicting identities. Each computer must have the exact identity created by the bootstrap.

### 5E. Start Main Service

On MAIN-SERVICE-01:

```sh
rc remote_admin start
rc remote_admin enable
rc main_service_monitor start
rc main_service_monitor enable
```

If the computer is also your management terminal, launch the console in the foreground after starting the monitor:

```sh
lua /usr/bin/admin_crypto_test.lua
lua /usr/bin/station_admin.lua
```

The crypto test must pass before using the console.

## Stage 6 — First management-console verification

At the management console:

```text
discover
nodes
```

You should see 18 authenticated nodes:
- 16 CORE nodes;
- STATION-WITNESS;
- MAIN-SERVICE-01.

Select an archive node and test the file manager:

```text
use CORE-A4
info
ls /
ls /etc/station
logs 20
```

Test a small file download:

```text
get /etc/station/node.lua /home/CORE-A4-node.lua
```

Then select CORE-B4 and run `logs 20`. After a few events have been generated, both archive nodes should contain log records.

## Stage 7 — Future GitHub updates

Once the remote agents have been installed and verified, only the management computer needs Internet access for routine updates.

From the management console:

```text
update CORE-B1
```

The console downloads the role-appropriate files from the GitHub manifest and transfers them to that node. It stages files on disk with backup copies; it does not hot-reload or restart running Lua programs.

Update standby nodes first, verify them, then update the active member during a maintenance window. Do not issue simultaneous reboots to both members of a pair. Treat witness upgrades as a separate operation.

## Troubleshooting

### Bootstrap says the root filesystem is read-only

You are likely still booted from the OpenOS floppy. Run `install`, install OpenOS to the hard drive, reboot, and retry the bootstrap.

### Remote agent says it cannot identify the computer

The role configuration is missing or malformed. Re-run `station_bootstrap.lua` and select the correct role/ID. Do not hand-edit node IDs unless you know the exact pair/side configuration.

### OpenOS says an rc startup file is missing

Re-run the bootstrap for that role. It downloads both the program and its matching `/etc/rc.d/` wrapper.

### Management console discovers no nodes

Check:
- identical secret on manager and agents;
- matching network ID;
- modem is attached and powered;
- all remote agents are started;
- all machines can communicate over the same modem network;
- no duplicate client identity was cloned from another computer's disk.

### A computer was cloned from another disk

Do not boot two clones with the same node ID, module ID, or admin client ID. Re-run the bootstrap and assign the correct unique identity.

## Important boundaries

- The installer does not format disks or erase unrelated files.
- The previous secret shown in chat must not be reused.
- HMAC protects authenticity/integrity, not secrecy.
- The archive pair provides mirrored application-level logs, not hardware RAID.
- Automatic replay of logs after outages and coordinated fleet rollback are not in this release.
- The Main Service monitor remains read-only; it does not switch equipment or move fluids.
