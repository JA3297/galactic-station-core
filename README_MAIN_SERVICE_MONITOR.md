# Main Service Life Support Monitor

This is a read-only OpenComputers monitor for the Galactic Station Main Service Module.

## Files

- `main_service_monitor.lua`: live equipment monitor.
- `main_service_monitor_rc.lua`: OpenOS startup service.
- `station_api.lua`: station network API. Its heartbeat method accepts an optional service list so CORE-A6/B6 can identify module services accurately.

## Safety

The monitor invokes only a fixed allow-list of getters and status methods. It does not call:
- `setEnabled`
- `pullFluid` / `pushFluid`
- `pullItems` / `pushItems`
- `suck` / `drop`
- any redstone or machine configuration method

Calls are wrapped in `pcall`, as component drivers may expose methods with differing signatures. Getter errors are recorded instead of stopping the monitor.

The electric pump in the initial inventory exposed no component methods. It will be shown as having no readable OpenComputers API until an adapter or supported component is available.

## Install

On the Main Service computer:

```sh
wget -f https://raw.githubusercontent.com/JA3297/galactic-station-core/main/station_api.lua /tmp/station_api.lua
wget -f https://raw.githubusercontent.com/JA3297/galactic-station-core/main/main_service_monitor.lua /tmp/main_service_monitor.lua
cp /usr/lib/station_api.lua /usr/lib/station_api.lua.bak
cp /tmp/station_api.lua /usr/lib/station_api.lua
cp /tmp/main_service_monitor.lua /usr/bin/main_service_monitor.lua
```

Test interactively:

```sh
lua /usr/bin/main_service_monitor.lua
```

Stop with Ctrl+C.

For automatic startup after successful testing:

```sh
wget -f https://raw.githubusercontent.com/JA3297/galactic-station-core/main/main_service_monitor_rc.lua /tmp/main_service_monitor_rc.lua
cp /tmp/main_service_monitor_rc.lua /etc/rc.d/main_service_monitor.lua
rc main_service_monitor enable
```

Do not run the previous `main_service.lua` monitor or `module_agent` at the same time on this computer; both can consume modem events from the shared OpenOS event stream.

## Snapshot

Each refresh writes a detailed snapshot to:

`/var/station/main_service_snapshot.txt`

The terminal dashboard refreshes every five seconds.
