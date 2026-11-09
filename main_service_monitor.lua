-- Galactic Station - Main Service Life Support Monitor
-- Version 0.2.0
-- OpenComputers / OpenOS Lua 5.2
--
-- READ-ONLY: calls only a fixed allow-list of status/getter methods.
-- Never calls setEnabled, pullFluid, pushFluid, suck, drop, bind, or other
-- equipment-control / transfer methods.
--
-- Run manually:
--   lua /usr/bin/main_service_monitor.lua
--
-- Stop with Ctrl+C.
--
-- Requires /usr/lib/station_api.lua and /etc/station/module.lua for
-- heartbeat/telemetry publishing. Monitoring remains local if unavailable.

local component = require("component")
local computer = require("computer")
local event = require("event")

local VERSION = "0.2.0"
local MODULE_ID = "MAIN-SERVICE-01"
local REFRESH_SECONDS = 5
local TELEMETRY_SECONDS = 15
local HEARTBEAT_SECONDS = 4

local station
local stationError
do
  local ok, result = pcall(require, "station_api")
  if ok then
    station = result
    local idOK, id = pcall(result.moduleId)
    if idOK and id then MODULE_ID = tostring(id) end
  else
    stationError = tostring(result)
  end
end

-- Strict allow-list of no-argument read-only methods seen in this hardware
-- inventory. A method is invoked only if the component actually exposes it.
local READ_METHODS = {
  "isEnabled",
  "isSealed",
  "isThermalControlEnabled",
  "isThermalControlWorking",
  "getOxygenTank",
  "getOxygen",
  "getTanks",
  "getWaterTank",
  "getWater",
  "getHydrogen",
  "getHydrogenNeeded",
  "getEnergyStored",
  "getEnergyCapacity",
  "getEnergy",
  "getEnergyNeeded",
  "getDemandedEnergy",
  "getEUStored",
  "getEUCapacity",
  "getEUOutput",
  "getOutput",
  "getMaxEnergy",
  "getMaxEnergyStored",
  "getStoredEnergy",
  "getRFStored",
  "getRFCapacity",
  "getTransferLocations"
}

local function sortedKeys(t)
  local out = {}
  for k in pairs(t or {}) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function safeText(value, depth)
  depth = depth or 0
  local kind = type(value)
  if kind == "nil" then return "nil" end
  if kind == "boolean" or kind == "number" then return tostring(value) end
  if kind == "string" then
    if #value > 100 then return string.format("%q...", value:sub(1, 100)) end
    return string.format("%q", value)
  end
  if kind ~= "table" then return "<" .. kind .. "> " .. tostring(value) end
  if depth >= 2 then return "{...}" end
  local parts, count = {}, 0
  for _, key in ipairs(sortedKeys(value)) do
    count = count + 1
    if count > 8 then
      parts[#parts + 1] = "..."
      break
    end
    parts[#parts + 1] = tostring(key) .. "=" .. safeText(value[key], depth + 1)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function findCategory(typeName)
  local s = string.lower(typeName or "")
  if s:find("oxygen", 1, true) and s:find("sealer", 1, true) then
    return "OXYGEN_SEALER"
  elseif s:find("separator", 1, true) then
    return "ELECTROLYTIC_SEPARATOR"
  elseif s:find("generator", 1, true) then
    return "GAS_GENERATOR"
  elseif s:find("energy_cube", 1, true) or s:find("energy cube", 1, true) then
    return "ENERGY_CUBE"
  elseif s:find("pump", 1, true) then
    return "PUMP"
  elseif s:find("oxygen_pipe", 1, true) then
    return "OXYGEN_PIPE"
  elseif s:find("energy_device", 1, true) then
    return "ENERGY_DEVICE"
  end
  return nil
end

local function discoverEquipment()
  local found = {}
  for address, typeName in component.list() do
    typeName = tostring(typeName)
    local category = findCategory(typeName)
    if category then
      found[#found + 1] = {
        address = tostring(address),
        typeName = typeName,
        category = category
      }
    end
  end
  table.sort(found, function(a, b)
    if a.category == b.category then
      if a.typeName == b.typeName then return a.address < b.address end
      return a.typeName < b.typeName
    end
    return a.category < b.category
  end)
  return found
end

local function getExposedMethods(address)
  local ok, methods = pcall(component.methods, address)
  if not ok or type(methods) ~= "table" then return {} end
  return methods
end

local function readGetter(address, methodName)
  -- component.invoke dispatches a component method. pcall contains signature
  -- mismatches/unsupported methods without affecting the monitor loop.
  local result = { pcall(component.invoke, address, methodName) }
  if not result[1] then
    return nil, "ERROR: " .. tostring(result[2])
  end
  local values = {}
  for i = 2, #result do values[#values + 1] = result[i] end
  if #values == 0 then return "no return value" end
  if #values == 1 then return values[1] end
  return values
end

local function sampleEquipment(item)
  local methods = getExposedMethods(item.address)
  local readings = {}
  local invoked = 0
  for _, methodName in ipairs(READ_METHODS) do
    if methods[methodName] then
      local value, err = readGetter(item.address, methodName)
      readings[methodName] = {value = value, error = err}
      invoked = invoked + 1
    end
  end
  item.readings = readings
  item.readableMethodCount = invoked
  item.exposedMethodCount = #sortedKeys(methods)
  return item
end

local function findNumeric(value)
  if type(value) == "number" then return value end
  if type(value) == "table" then
    if type(value[1]) == "number" then return value[1] end
    for _, v in pairs(value) do
      if type(v) == "number" then return v end
    end
  end
  return nil
end

local function numericReading(item, methodName)
  local entry = item.readings and item.readings[methodName]
  if not entry or entry.error then return nil end
  return findNumeric(entry.value)
end

local function firstNumeric(item, names)
  for _, name in ipairs(names) do
    local value = numericReading(item, name)
    if value ~= nil then return value, name end
  end
  return nil
end

local function firstReading(item, names)
  for _, name in ipairs(names) do
    local entry = item.readings and item.readings[name]
    if entry and not entry.error and entry.value ~= nil then
      return entry.value, name
    end
  end
  return nil
end

local function formatPercent(stored, capacity)
  if stored == nil or capacity == nil or capacity <= 0 then return nil end
  return string.format("%.1f%%", math.max(0, math.min(100, stored / capacity * 100)))
end

local function lineFor(item)
  local parts = {}
  local function append(label, names)
    local value = firstReading(item, names)
    if value ~= nil then
      parts[#parts + 1] = label .. "=" .. safeText(value)
    end
  end

  if item.category == "OXYGEN_SEALER" then
    append("enabled", {"isEnabled"})
    append("sealed", {"isSealed"})
    append("thermal", {"isThermalControlWorking"})
    append("oxygenTank", {"getOxygenTank", "getOxygen", "getTanks"})
    append("energy", {"getEnergyStored", "getEUStored"})
  elseif item.category == "ELECTROLYTIC_SEPARATOR" then
    append("hydrogen", {"getHydrogen"})
    append("hydrogenNeeded", {"getHydrogenNeeded"})
    append("tanks", {"getTanks"})
    append("energy", {"getEnergyStored", "getEUStored"})
    append("energyNeeded", {"getEnergyNeeded", "getDemandedEnergy"})
  elseif item.category == "GAS_GENERATOR" then
    append("energy", {"getEnergyStored", "getEUStored", "getStoredEnergy"})
    append("capacity", {"getEnergyCapacity", "getEUCapacity", "getMaxEnergyStored"})
    append("output", {"getEUOutput", "getOutput", "getEnergy"})
    append("demand", {"getEnergyNeeded", "getDemandedEnergy"})
  elseif item.category == "ENERGY_CUBE" or item.category == "ENERGY_DEVICE" then
    local stored, storedMethod = firstNumeric(item, {"getEnergyStored", "getEUStored", "getStoredEnergy", "getRFStored"})
    local capacity, capacityMethod = firstNumeric(item, {"getEnergyCapacity", "getEUCapacity", "getMaxEnergyStored", "getRFCapacity"})
    if stored ~= nil then parts[#parts + 1] = storedMethod .. "=" .. tostring(stored) end
    if capacity ~= nil then parts[#parts + 1] = capacityMethod .. "=" .. tostring(capacity) end
    local percent = formatPercent(stored, capacity)
    if percent then parts[#parts + 1] = "charge=" .. percent end
  elseif item.category == "PUMP" then
    if item.exposedMethodCount == 0 then
      parts[#parts + 1] = "NO OPENCOMPUTERS METHODS EXPOSED"
    else
      append("energy", {"getEnergyStored", "getEUStored"})
      append("tanks", {"getTanks", "getWaterTank"})
    end
  elseif item.category == "OXYGEN_PIPE" then
    append("tanks", {"getTanks"})
    append("size", {"size"})
  end

  if #parts == 0 then
    if item.exposedMethodCount == 0 then
      return "No component methods exposed"
    end
    return "Component exposed; no whitelisted no-argument readings returned"
  end
  return table.concat(parts, " | ")
end

local function sendTelemetry(field, value, unit, resource)
  if not station then return end
  local ok, err = pcall(station.telemetry, field, value, unit, resource)
  if not ok then print("Telemetry send warning: " .. tostring(err)) end
end

local function publishReadings(items)
  if not station then return end
  for _, item in ipairs(items) do
    local prefix = string.lower(item.category) .. "_" .. item.address:sub(1, 8)
    local stored = firstNumeric(item, {"getEnergyStored", "getEUStored", "getStoredEnergy", "getRFStored"})
    local capacity = firstNumeric(item, {"getEnergyCapacity", "getEUCapacity", "getMaxEnergyStored", "getRFCapacity"})
    if stored ~= nil then sendTelemetry("main_service_" .. prefix .. "_energy_stored", stored, "energy", item.category) end
    if capacity ~= nil then sendTelemetry("main_service_" .. prefix .. "_energy_capacity", capacity, "energy", item.category) end

    if item.category == "OXYGEN_SEALER" then
      local sealed = firstReading(item, {"isSealed"})
      local enabled = firstReading(item, {"isEnabled"})
      if type(sealed) == "boolean" then sendTelemetry("main_service_" .. prefix .. "_sealed", sealed and 1 or 0, "boolean", "oxygen_sealer") end
      if type(enabled) == "boolean" then sendTelemetry("main_service_" .. prefix .. "_enabled", enabled and 1 or 0, "boolean", "oxygen_sealer") end
    elseif item.category == "GAS_GENERATOR" then
      local output = firstNumeric(item, {"getEUOutput", "getOutput", "getEnergy"})
      if output ~= nil then sendTelemetry("main_service_" .. prefix .. "_output", output, "energy_per_tick", "generator") end
    end
  end
end

local function render(items, errorList)
  local ok, term = pcall(require, "term")
  if ok and term and term.clear then pcall(term.clear) end

  print("============================================================")
  print(" GALACTIC STATION | MAIN SERVICE LIFE SUPPORT")
  print("============================================================")
  print("Controller: " .. VERSION .. " | Module: " .. MODULE_ID)
  print(string.format("Uptime: %.1f s | Computer memory free: %d / %d bytes",
    computer.uptime(), computer.freeMemory(), computer.totalMemory()))
  print("Station network: " .. (station and "CONNECTED" or "LOCAL ONLY"))
  if stationError then print("Station API: " .. stationError) end
  print("")

  local totals = {}
  for _, item in ipairs(items) do
    totals[item.category] = (totals[item.category] or 0) + 1
    print(string.format("[%s] %s", item.category, item.typeName))
    print("Address: " .. item.address)
    print("Readings: " .. lineFor(item))
    if item.category == "ENERGY_CUBE" or item.category == "ENERGY_DEVICE" or item.category == "GAS_GENERATOR" then
      local stored = firstNumeric(item, {"getEnergyStored", "getEUStored", "getStoredEnergy", "getRFStored"})
      local capacity = firstNumeric(item, {"getEnergyCapacity", "getEUCapacity", "getMaxEnergyStored", "getRFCapacity"})
      local percent = formatPercent(stored, capacity)
      if percent then print("Energy charge: " .. percent) end
    end
    print("Methods: " .. tostring(item.exposedMethodCount) .. " exposed; " .. tostring(item.readableMethodCount) .. " safe getters sampled")
    print("------------------------------------------------------------")
  end

  print("EQUIPMENT COUNTS")
  for _, category in ipairs({"OXYGEN_SEALER", "PUMP", "ELECTROLYTIC_SEPARATOR", "GAS_GENERATOR", "ENERGY_CUBE", "ENERGY_DEVICE", "OXYGEN_PIPE"}) do
    print(string.format("  %-26s %d", category, totals[category] or 0))
  end
  if errorList and #errorList > 0 then
    print("")
    print("READ WARNINGS")
    for i = 1, math.min(#errorList, 5) do print("  " .. errorList[i]) end
  end
  print("")
  print("READ-ONLY MODE. Equipment is not being switched or reconfigured.")
  print("Refresh: " .. REFRESH_SECONDS .. " seconds | Stop: Ctrl+C")
end

local function saveSnapshot(items)
  local lines = {
    "GALACTIC STATION - MAIN SERVICE LIVE SNAPSHOT",
    "Version: " .. VERSION,
    "Module: " .. MODULE_ID,
    "Uptime: " .. tostring(computer.uptime()),
    "Read-only status sampling; no control methods invoked.",
    ""
  }
  for _, item in ipairs(items) do
    lines[#lines + 1] = item.category .. " | " .. item.typeName .. " | " .. item.address
    for _, methodName in ipairs(sortedKeys(item.readings)) do
      local reading = item.readings[methodName]
      if reading.error then
        lines[#lines + 1] = "  " .. methodName .. " = " .. reading.error
      else
        lines[#lines + 1] = "  " .. methodName .. " = " .. safeText(reading.value)
      end
    end
    lines[#lines + 1] = ""
  end
  local file = io.open("/var/station/main_service_snapshot.txt", "w")
  if file then file:write(table.concat(lines, "\n"), "\n"); file:close() end
end

print("Starting read-only equipment discovery...")
local lastHeartbeat, lastTelemetry, lastRefresh = 0, 0, 0
local items = {}
local errorList = {}

while true do
  local now = computer.uptime()

  if now - lastRefresh >= REFRESH_SECONDS then
    items = discoverEquipment()
    errorList = {}
    for _, item in ipairs(items) do
      sampleEquipment(item)
      for methodName, reading in pairs(item.readings) do
        if reading.error then
          errorList[#errorList + 1] = item.typeName .. "." .. methodName .. ": " .. reading.error
        end
      end
    end
    render(items, errorList)
    saveSnapshot(items)
    lastRefresh = now
  end

  if station and now - lastHeartbeat >= HEARTBEAT_SECONDS then
    local ok, err = pcall(station.heartbeat)
    if not ok then errorList[#errorList + 1] = "Heartbeat: " .. tostring(err) end
    lastHeartbeat = now
  end

  if station and now - lastTelemetry >= TELEMETRY_SECONDS then
    publishReadings(items)
    sendTelemetry("main_service_uptime", computer.uptime(), "seconds", "controller")
    sendTelemetry("main_service_component_count", #items, "components", "controller")
    lastTelemetry = now
  end

  event.pull(0.5)
end
