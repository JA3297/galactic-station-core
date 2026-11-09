GALACTIC STATION CORE — QUICK START

1. Install OpenOS on every core computer. This package targets the classic
   OpenComputers component/event/serialization APIs and Lua 5.2.

2. Put a modem on every computer. Connect the computers to one OpenComputers
   network. For real redundancy, build two physically separate network paths
   and attach both where your OC version/modpack supports it.

3. On every one of the 16 core computers:
   mkdir /etc/station
   mkdir /usr/lib
   Copy station.lua to /usr/bin/station.lua
   Copy its matching configs/server_*.lua to /etc/station/node.lua
   Copy examples/safety_rules.lua to /etc/station/safety_rules.lua
   Copy examples/acl.lua to /etc/station/acl.lua

   IMPORTANT: Each computer gets exactly ONE matching node configuration.
   Do not give two computers the same node_id. Rack A uses side A; Rack B uses B.

4. On the dedicated witness computer:
   mkdir /etc/station
   Copy witness.lua to /usr/bin/witness.lua
   Copy configs/witness.lua to /etc/station/witness.lua
   Run: witness

5. Start the 16 core computers:
   Run: station
   Wait for the witness boot guard, then verify each pair has exactly one ACTIVE
   computer and one STANDBY computer.

6. Optional autostart:
   Copy station_rc.lua to /etc/rc.d/station.lua
   Run: rc station enable
   Reboot and verify the service is running. The witness can be started the same
   way using a separate rc service that runs /usr/bin/witness.lua.

7. Configure your module-local controllers:
   Copy examples/module.lua to /etc/station/module.lua and edit module_id.
   Install station_api.lua as /usr/lib/station_api.lua.
   Use require("station_api") from your own controller to publish telemetry:
     local station = require("station_api")
     station.telemetry("temperature", 21.5, "C")
     station.telemetry("reserve_level", 82, "%", "reserve_level")
     station.event("filter_service_due", "NOTICE", "Maintenance interval reached")

8. Safety rules:
   Add rules to /etc/station/safety_rules.lua using the exact telemetry field
   names your modules publish. Rules are intentionally empty by default.

9. Command authorization flow:
   a. Module requests permission:
      local id = station.requestAccess("station_commander", "command", "LIFE-SUPPORT")
   b. Its program waits for an access_response packet with that request_id.
   c. If approved, it calls station.command(operator, id, approval_id,
      target_module_id, action_name, args_table).
   d. The command core relays the request. The receiving module MUST validate
      the request locally and decide whether it is safe to execute.

10. The core code deliberately does not actuate Galacticraft machines, redstone,
    generators, valves, doors, or life-support equipment. Implement those actions
    in each module's local controller and add independent local interlocks.

Network ID:
  The supplied configs use GALACTIC-STATION-01. Keep it identical on all
  16 core computers, the witness, and module agents.

Default modem port: 45821.
