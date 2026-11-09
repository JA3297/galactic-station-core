-- Galactic Station: Main Service Module Controller
-- Version: 0.1.0 (read-only discovery and reporting)
-- Target: OpenComputers / OpenOS, Lua 5.2
--
-- SAFETY: This version DOES NOT switch machines, change redstone, alter Mekanism
-- sides/modes, enable/disable Oxygen Sealers, or issue equipment commands.
-- It discovers exposed components, reports their methods, and publishes
-- controller/computer health to the Galactic Station network.
--
-- One-shot hardware report:
--   lua /usr/bin/main_service.lua scan
-- Continuous monitor:
--   lua /usr/bin/main_service.lua

local component = require("component")
local computer = require("computer")
local serialization = require("serialization")

local VERSION = "0.1.0"
local REPORT_PATH = "/tmp/main_service_hardware_report.txt"
local MODULE_CONFIG = "/etc/station/module.lua"

local function safeRequire(name)
  local ok, value = pcall(require, name)
  if ok then return value end
  return nil, tostring(value)
end

local function sortedKeys(t)
  local result = {}
  for k in pairs(t or {}) do result[#result + 1] = k end
  table.sort(result)
  return result
end

local function classify(typeName)
  local s = string.lower(typeName or "")
  if s:find("sealer", 1, true) and s:find("oxygen", 1, true) then
    return "OXYGEN_SEALER"
  elseif s:find("pump", 1, true) then
    return "WATER_PUMP_OR_OTHER_PUMP"
  elseif s:find("separator", 1, true) or s:find("electrolytic", 1, true) then
    return "ELECTROLYTIC_SEPARATOR"
  elseif s:find("generator", 1, true) then
    return "GENERATOR"
  elseif s:find("energy", 1, true) and s:find("cube", 1, true) then
    return "ENERGY_CUBE"
  elseif s == "adapter" then
    return "OPENCOMPUTERS_ADAPTER"
  end
  return "OTHER"
end

local function collectComponents()
  local found = {}
  for address, typeName in component.list() do
    found[#found + 1] = {
      address = tostring(address),
      typeName = tostring(typeName),
      category = classify(tostring(typeName))
    }
  end
  table.sort(found, function(a, b)
    if a.typeName == b.typeName then return a.address < b.address end
    return a.typeName < b.typeName
  end)
  return found
end

local function countByCategory(found)
  local counts = {
    OXYGEN_SEALER = 0,
    WATER_PUMP_OR_OTHER_PUMP = 0,
    ELECTROLYTIC_SEPARATOR = 0,
    GENERATOR = 0,
    ENERGY_CUBE = 0,
    OPENCOMPUTERS_ADAPTER = 0,
    OTHER = 0
  }
  for _, item in ipairs(found) do
    counts[item.category] = (counts[item.category] or 0) + 1
  end
  return counts
end

local function getMethodNames(address)
  local ok, methods = pcall(component.methods, address)
  if not ok or type(methods) ~= "table" then return {}, tostring(methods) end
  local names = {}
  for name in pairs(methods) do names[#names + 1] = tostring(name) end
  table.sort(names)
  return names
end

local function getMethodDoc(address, methodName)
  local ok, result = pcall(component.doc, address, methodName)
  if not ok then return "[documentation error: " .. tostring(result) .. "]" end
  if result == nil or result == "" then return "[no method documentation exposed]" end
  return tostring(result):gsub("\r", ""):gsub("\n", " ")
end

local function writeHardwareReport(found)
  local lines = {}
  local counts = countByCategory(found)
  lines[#lines + 1] = "GALACTIC STATION - MAIN SERVICE MODULE HARDWARE REPORT"
  lines[#lines + 1] = "Controller version: " .. VERSION
  lines[#lines + 1] = "Computer uptime: " .. string.format("%.1f", computer.uptime()) .. " seconds"
  lines[#lines + 1] = "Total exposed components: " .. tostring(#found)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "CATEGORY COUNTS"
  for _, key in ipairs(sortedKeys(counts)) do
    lines[#lines + 1] = string.format("  %-32s %d", key, counts[key])
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "COMPONENTS AND READ-ONLY API DOCUMENTATION"

  for index, item in ipairs(found) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("[%d] TYPE: %s", index, item.typeName)
    lines[#lines + 1] = "    CATEGORY: " .. item.category
    lines[#lines + 1] = "    ADDRESS: " .. item.address
    local methods, methodError = getMethodNames(item.address)
    if methodError then
      lines[#lines + 1] = "    METHODS ERROR: " .. methodError
    elseif #methods == 0 then
      lines[#lines + 1] = "    METHODS: [none exposed]"
    else
      lines[#lines + 1] = "    METHODS (names and docs; no methods are invoked):"
      for _, methodName in ipairs(methods) do
        lines[#lines + 1] = "      - " .. methodName .. " : " .. getMethodDoc(item.address, methodName)
      end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "SAFETY NOTE"
  lines[#lines + 1] = "This report only enumerates component names, method names, and documentation."
  lines[#lines + 1] = "It does not call machine methods or change equipment state."

  local text = table.concat(lines, "\n") .. "\n"
  local file, err = io.open(REPORT_PATH, "w")
  if not file then return nil, "Could not write report: " .. tostring(err) end
  file:write(text)
  file:close()
  return true, #lines
end

local function printSummary(found)
  local counts = countByCategory(found)
  print("============================================================")
  print(" GALACTIC STATION | MAIN SERVICE MODULE CONTROLLER " .. VERSION)
  print("============================================================")
  print("Exposed components: " .. tostring(#found))
  print("Oxygen sealers:     " .. tostring(counts.OXYGEN_SEALER))
  print("Pumps:              " .. tostring(counts.WATER_PUMP_OR_OTHER_PUMP))
  print("Electrolytic units: " .. tostring(counts.ELECTROLYTIC_SEPARATOR))
  print("Generators:         " .. tostring(counts.GENERATOR))
  print("Energy cubes:       " .. tostring(counts.ENERGY_CUBE))
  print("OC adapters:        " .. tostring(counts.OPENCOMPUTERS_ADAPTER))
  print("Other components:   " .. tostring(counts.OTHER))
  print("Hardware report:    " .. REPORT_PATH)
  print("============================================================")
  if counts.OXYGEN_SEALER == 0 or counts.ELECTROLYTIC_SEPARATOR == 0 or
     counts.GENERATOR == 0 or counts.ENERGY_CUBE == 0 then
    print("NOTE: One or more expected machines are not exposed as components.")
    print("Check the adapter placement/driver support and inspect the report.")
  end
end

local mode = ...
local found = collectComponents()
local wrote, reportInfo = writeHardwareReport(found)
printSummary(found)
if not wrote then print("REPORT ERROR: " .. tostring(reportInfo)) end

if mode == "scan" then
  print("One-shot scan complete. No machine methods were invoked.")
  return
end

local station, stationError = safeRequire("station_api")
if not station then
  print("Station network API unavailable: " .. tostring(stationError))
  print("Local hardware discovery will continue; no station telemetry will be sent.")
else
  print("Station network API loaded. Module heartbeat/telemetry enabled.")
end

local lastHeartbeat = 0
local lastTelemetry = 0
local lastReport = 0
local lastComponentSignature = ""
local lastNetworkError = nil
local event = require("event")

local function signature(items)
  local parts = {}
  for _, item in ipairs(items) do
    parts[#parts + 1] = item.typeName .. "@" .. item.address
  end
  return table.concat(parts, "|")
end

local function publishTelemetry(items)
  if not station then return end
  local counts = countByCategory(items)
  local total = computer.totalMemory()
  local free = computer.freeMemory()
  local modemCount = 0
  local adapterCount = counts.OPENCOMPUTERS_ADAPTER
  for _, item in ipairs(items) do
    if item.typeName == "modem" then modemCount = modemCount + 1 end
  end

  local samples = {
    {"main_service_uptime", computer.uptime(), "s"},
    {"main_service_memory_free", free, "bytes"},
    {"main_service_memory_total", total, "bytes"},
    {"main_service_component_count", #items, "components"},
    {"main_service_modem_count", modemCount, "modems"},
    {"main_service_adapter_count", adapterCount, "adapters"},
    {"main_service_oxygen_sealer_components", counts.OXYGEN_SEALER, "components"},
    {"main_service_pump_components", counts.WATER_PUMP_OR_OTHER_PUMP, "components"},
    {"main_service_separator_components", counts.ELECTROLYTIC_SEPARATOR, "components"},
    {"main_service_generator_components", counts.GENERATOR, "components"},
    {"main_service_energy_cube_components", counts.ENERGY_CUBE, "components"}
  }
  for _, sample in ipairs(samples) do
    local ok, err = pcall(station.telemetry, sample[1], sample[2], sample[3])
    if not ok then
      lastNetworkError = tostring(err)
      break
    end
  end
end

print("Controller running in READ-ONLY mode. Press Ctrl+C to stop.")
while true do
  local now = computer.uptime()

  if station and now - lastHeartbeat >= 4 then
    local ok, err = pcall(station.heartbeat)
    if not ok then lastNetworkError = tostring(err) end
    lastHeartbeat = now
  end

  if now - lastReport >= 30 then
    local current = collectComponents()
    local currentSignature = signature(current)
    if currentSignature ~= lastComponentSignature then
      found = current
      lastComponentSignature = currentSignature
      local ok, err = writeHardwareReport(found)
      if not ok then print("Report refresh failed: " .. tostring(err)) end
      print("Hardware inventory changed; report refreshed.")
    else
      found = current
    end
    lastReport = now
  end

  if now - lastTelemetry >= 15 then
    publishTelemetry(found)
    local counts = countByCategory(found)
    print(string.format("[%7.1fs] LIFE SUPPORT MODULE | components=%d | sealers=%d | pumps=%d | separator=%d | generators=%d | energy cubes=%d",
      now, #found, counts.OXYGEN_SEALER, counts.WATER_PUMP_OR_OTHER_PUMP,
      counts.ELECTROLYTIC_SEPARATOR, counts.GENERATOR, counts.ENERGY_CUBE))
    if lastNetworkError then
      print("Station telemetry warning: " .. lastNetworkError)
      lastNetworkError = nil
    end
    lastTelemetry = now
  end

  -- Pull only a station-network modem packet. The module agent should not be
  -- run concurrently on this computer because both programs would consume
  -- messages from the same modem event stream.
  if station then
    local ok, packet = pcall(station.pull, 0.5)
    if ok and packet then
      local data = packet.data or {}
      if packet.kind == "station_alarm" then
        print("STATION ALARM: " .. tostring(data.label) .. " / " .. tostring(data.severity))
      elseif packet.kind == "station_emergency" then
        print("*** STATION EMERGENCY: " .. tostring(data.message) .. " ***")
      elseif packet.kind == "command_dispatch" then
        print("COMMAND RECEIVED: " .. tostring(data.action) .. " — NOT EXECUTED (read-only controller)")
        pcall(station.event, "main_service_command_not_executed", "NOTICE", tostring(data.action))
      end
    elseif not ok then
      lastNetworkError = tostring(packet)
    end
  else
    event.pull(0.5)
  end
end
