-- Optional module communications/diagnostic agent. Does NOT control hardware.
-- Install as /usr/bin/module_agent.lua and configure /etc/station/module.lua.
local computer = require("computer")
local event = require("event")
local station = require("station_api")
local CFG = dofile("/etc/station/module.lua")
local logger
do
  local ok, value = pcall(require, "station_logger")
  if ok then logger = value end
end
local function log(level, message, fields)
  if logger and logger.write then
    pcall(logger.write, level, "module_agent", message, fields)
  end
end
local lastHeartbeat = 0
local lastStatus = 0

print("Station module agent: " .. CFG.module_id)
print("Local subsystem controllers remain authoritative for their equipment.")
log("INFO", "Module agent started", {module_id = CFG.module_id})

while true do
  local t = computer.uptime()
  if t - lastHeartbeat >= 4 then
    station.heartbeat()
    lastHeartbeat = t
  end
  if t - lastStatus >= 30 then
    station.requestStatus("module-status-" .. tostring(math.floor(t)))
    lastStatus = t
  end

  local packet = station.pull(0.5)
  if packet then
    if packet.kind == "command_dispatch" then
      local d = packet.data or {}
      print("COMMAND REQUEST for this module: " .. tostring(d.action) .. " (" .. tostring(d.request_id) .. ")")
      print("Not executed. Implement and validate this action in the module's local controller.")
      log("WARNING", "Command request received but not executed", {action = d.action, request_id = d.request_id})
      station.event("command_received", "NOTICE", tostring(d.request_id) .. " / " .. tostring(d.action))
    elseif packet.kind == "station_alarm" then
      print("STATION ALARM: " .. tostring(packet.data.label) .. " / " .. tostring(packet.data.severity))
      log("WARNING", "Station alarm received", {label = packet.data.label, severity = packet.data.severity})
    elseif packet.kind == "station_emergency" then
      print("STATION EMERGENCY: " .. tostring(packet.data.message))
      log("ERROR", "Station emergency received", {message = packet.data.message})
    elseif packet.kind == "status_response" then
      print("Station status: " .. tostring(packet.data.active_nodes) .. " active nodes; " .. tostring(packet.data.alarms) .. " active alarms")
      log("DEBUG", "Station status response received", {active_nodes = packet.data.active_nodes, alarms = packet.data.alarms})
    end
  end
end
