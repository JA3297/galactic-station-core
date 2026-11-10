# Remote Administration, GitHub Deployment, and Central Logging

## What this adds

The management plane is separate from the existing lease/telemetry network:

| Port | Purpose |
|---:|---|
| 45821 | Existing Galactic Station leases, heartbeats, telemetry, alarms |
| 45822 | Authenticated remote administration and file transfer |
| 45823 | Authenticated structured log stream to the archive pair |

The remote agent uses OpenOS `event.listen("modem_message", ...)` driver mode. It does not run a second independent modem polling loop, so the existing station runtime can continue using `event.pull()`.

## Security model and limitations

- Messages on ports 45822 and 45823 are authenticated with HMAC-SHA256 using a shared secret stored at `/etc/station/remote_admin.key`.
- The secret is never stored in this public repository or included in the deployment manifest.
- Each client has a monotonically increasing request sequence. Agents persist the last accepted sequence per client to reject replays.
- Broadcast requests are restricted to discovery. File writes, deletes, moves, and reboots must target one named computer.
- The remote command set is deliberately allow-listed: `uptime`, `memory`, `components`, `mounts`, and `services`. There is no arbitrary shell or arbitrary Lua evaluation in this release.
- File reads/writes are remote administration operations. The key and node identity files are protected from remote read/write/delete. Critical filesystem roots cannot be deleted.
- Remote deletion requires a local console confirmation. Remote reboot requires typing the exact node-specific phrase.
- **This is not full SSH.** HMAC protects authenticity and integrity, but modem packets are not encrypted. A person able to sniff the in-game network may be able to read file-transfer contents. Keep the modem network physically/logically trusted and do not bridge it to untrusted players.
- This first release uses one shared key on the manager and every managed host to keep 17-computer provisioning manageable. Consequently, **compromise of any one managed computer exposes the key used to administer every other computer**. Anyone who can read the key on a host can impersonate the manager. Do not enable this on a station where untrusted players can open terminals or read host files. Rotate the secret on every host if it is exposed.
- This is a trusted-network v1, not full SSH: it has no packet encryption, per-node credentials, or public-key identity. A later hardened release should replace the shared key with per-host keys or manager-only digital signatures before exposing it to a wider multiplayer environment.
- Remote admin is for trusted in-game administration, not a hardened security boundary against server operators or malicious modpack code.

## Remote console commands

Launch with:

```sh
lua /usr/bin/station_admin.lua
```

Then use:

```text
discover
nodes
use CORE-A1
info
ls /
ls /etc/station
cat /var/station/events.log
get /var/station/logs/station.log /home/station.log
put /home/new_config.lua /etc/station/new_config.lua
mkdir /home/maintenance
mv /home/old.txt /home/archive/old.txt
exec uptime
exec memory
exec components
exec mounts
exec services
logs 80
reboot
update CORE-B1
```

Paths in `ls`, `cat`, `get`, `put`, `mkdir`, `rm`, and `mv` are remote paths after selecting a node. Paths with spaces may be quoted. The CLI's `rm` command requires typing `DELETE`; `reboot` requires typing `REBOOT <node-id>`.

## GitHub update model

The central console reads `deploy/manifest.lua` from the public repository, downloads the listed files over the manager computer's Internet Card, then transfers them to the selected target over port 45822. The managed target computers do not need Internet access after initial agent installation.

The manifest never deploys these local identity/security files:

- `/etc/station/remote_admin.key`
- `/etc/station/node.lua`
- `/etc/station/witness.lua`
- `/etc/station/module.lua`
- `/etc/station/install_role`

Each changed file is staged through a temporary file in its destination directory and renamed into place after the final chunk. If the destination existed, a `.gsa-backup` copy is retained.

An update stages files on disk; it does **not** replace code already loaded into a running Lua process. Use the console's confirmed `reboot` command one computer at a time during maintenance. Update standby members first, verify they return, then update active members. Treat witness maintenance as a separate operation because the witness currently arbitrates all eight leases.

## Central logging

All managed computers can use `/usr/lib/station_logger.lua`:

- a local rotating spool is written to `/var/station/log-spool/active.log` (plus two rotations);
- structured records are HMAC-authenticated and broadcast to port 45823;
- both CORE-A4 and CORE-B4 run the log collector and store independent copies at `/var/station/logs/station.log`;
- the archive log rotates at 512 KiB with four old rotations;
- duplicate packets are suppressed using record IDs.

The local spool preserves records when the archive link is unavailable, but this version does not yet implement acknowledgement/replay from the local spool. Retrieve a host's local spool with the remote console's `get` command if you need records that did not reach A4/B4.

The current integration sends station core events, witness lease grants/expirations, remote-admin audit records, module-agent command/alarm visibility, and Main Service monitor start/getter-warning changes. It does not capture every arbitrary `print()` written by every Lua program.

**This is an application-level mirrored archive, not RAID.** CORE-A4 and CORE-B4 each store a copy on their own local filesystem. That protects against losing one archive computer, but it is not a hardware RAID array and does not guarantee the two copies are always perfectly synchronized during a power/network failure.

View the last log lines after selecting CORE-A4 or CORE-B4:

```text
logs 100
```

The console also has a diagnostic export helper:

```text
collect CORE-A4
collect all
```

`collect all` runs the same export for every node returned by the most recent `discover`. It saves the node identity, recent local station events, local logger spool, recent central archive log, and (when present) a bounded Main Service snapshot to `/home/station-diagnostics/CORE-A4/` on the management computer. You can then inspect or transfer those files from the manager.

Export a full log to the management computer:

```text
get /var/station/logs/station.log /home/archive-A4.log
```

Do not automatically publish live logs to the public GitHub repository. Logs can contain operational details. Export them to the control computer and upload them privately or attach them to a ChatGPT conversation for analysis.

## Initial deployment

### 1. Choose the management computer

Use one computer with:
- a modem connected to the station network;
- an Internet Card for GitHub downloads;
- OpenOS;
- a writable filesystem.

It may be the Main Service computer if that is your convenient control station. The manager console can run in the foreground while the station monitor remains in its own rc-managed thread.

### 2. Install the management console locally

```sh
wget -f https://raw.githubusercontent.com/JA3297/galactic-station-core/main/station_admin_install.lua /tmp/station_admin_install.lua
lua /tmp/station_admin_install.lua
```

This installs `/usr/lib/admin_crypto.lua`, `/usr/bin/station_admin.lua`, the key setup utility, and a cryptography self-test.

Run the self-test before provisioning a key:

```sh
lua /usr/bin/admin_crypto_test.lua
```

Proceed only if it reports that all cryptography tests passed.

### 3. Create one high-entropy shared secret

Use a password manager or a Data Card Tier 2+ random generator to make a random secret of at least 64 characters. Do not use a guessable phrase.

On the management computer, run:

```sh
lua /usr/bin/admin_key_setup.lua
```

Paste the secret twice. The file is written to `/etc/station/remote_admin.key`.

Alternatively, if that computer has a Data Card that exposes `data.random()`:

```sh
lua /usr/bin/admin_key_setup.lua generate
```

Copy the generated 64-character hex value securely; you will enter the exact same value on each agent host.

### 4. Install and pair each managed computer

Run on each of the 16 core computers, the witness, and any module computer you want to manage:

```sh
wget -f https://raw.githubusercontent.com/JA3297/galactic-station-core/main/remote_admin_setup.lua /tmp/remote_admin_setup.lua
lua /tmp/remote_admin_setup.lua
```

Enter the same shared secret when prompted. This installs the cryptographic helper, remote agent, startup wrapper, and local logger. On CORE-A4 and CORE-B4 it also installs the archive collector.

Start and enable the agent now:

```sh
rc remote_admin start
rc remote_admin enable
```

On CORE-A4 and CORE-B4, also run:

```sh
rc station_log_collector start
rc station_log_collector enable
```

These commands start the services immediately and enable them for the next boot. OpenOS rc scripts support individual `start` and startup `enable` operations.

### 5. Start the central console

On the management computer:

```sh
lua /usr/bin/station_admin.lua
```

Then:

```text
discover
nodes
use CORE-A4
logs 50
```

If fewer than 17 nodes appear, verify that the remote agent is running, the shared key matches exactly, and the modem network reaches port 45822.

### 6. Enable structured logs

The logger library is installed by the bootstrap. The station runtime and witness must be restarted once after installation so they load the library and key. Do this during a maintenance window; restarting the witness briefly removes lease authority and causes core nodes to demote until it returns.

After both archive collectors are running and station/witness processes have restarted, generate a few known events and verify that the same records appear on both CORE-A4 and CORE-B4.

## First-run test plan

1. Install the agent and key on CORE-A4 and CORE-B4 only.
2. Start the agents, then run the manager and verify `discover` sees both nodes.
3. Test `info`, `ls /`, and `get` on a harmless file.
4. Install agents on the rest of the computers.
5. Start collectors on A4/B4 and verify mirrored logs.
6. Stage an update on one standby node, confirm the files and `.gsa-backup`, then use a node-specific reboot and verify it returns.
7. Only after the test succeeds, roll out to the remaining nodes.

Do not use `update all` followed by simultaneous reboots. Keep the witness online while rolling the core pairs.
