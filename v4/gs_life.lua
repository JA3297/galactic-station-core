-- Galactic Station v4 Main Service sampler.
-- READ ONLY: only invokes the allow-listed getters below. No setters,
-- fluid transfers, inventory transfers, redstone writes, or machine controls.

local component = require("component")
local M = {}

local GETTERS = {
  oxygen_sealer = {
    "isEnabled", "isSealed", "isThermalControlEnabled",
    "isThermalControlWorking", "getOxygenTank", "getOxygen",
    "getTanks", "getEnergyStored", "getEUStored"
  },
  electrolytic_separator = {
    "getHydrogen", "getHydrogenNeeded", "getTanks",
    "getEnergyStored", "getEUStored", "getEnergyNeeded",
    "getDemandedEnergy", "isEnabled"
  },
  gas_burning_generator = {
    "getEnergy", "getEUOutput", "getOutput", "getDemandedEnergy",
    "getEnergyStored", "getEUStored", "isEnabled"
  },
  elite_energy_cube = {
    "getEnergyStored", "getEnergyCapacity", "getEUStored",
    "getEUCapacity", "getMaxEnergy", "getMaxEnergyStored",
    "getOutput", "getRFStored", "getRFCapacity"
  },
  electric_pump = {
    "isEnabled", "getEnergyStored", "getTanks", "getWaterTank"
  },
  oxygen_pipe = {
    "getTanks", "getTransferLocations", "size"
  }
}

local function classify(typeName)
  local s = string.lower(tostring(typeName or ""))
  if s:find("oxygen_sealer", 1, true) then return "oxygen_sealer" end
  if s:find("electrolytic_separator", 1, true) then return "electrolytic_separator" end
  if s:find("gas_burning_generator", 1, true) then return "gas_burning_generator" end
  if s:find("elite_energy_cube", 1, true) then return "elite_energy_cube" end
  if s:find("electric_pump", 1, true) then return "electric_pump" end
  if s:find("oxygen_pipe", 1, true) then return "oxygen_pipe" end
  return nil
end

local function sanitize(value, depth)
  depth = depth or 0
  local t = type(value)
  if t == "nil" or t == "boolean" or t == "number" then return value end
  if t == "string" then return value:sub(1, 160) end
  if t ~= "table" or depth >= 2 then return tostring(value):sub(1, 120) end

  local result, count = {}, 0
  for k, v in pairs(value) do
    count = count + 1
    if count > 16 then break end
    local key = type(k) == "string" or type(k) == "number" and k or tostring(k)
    if key then result[key] = sanitize(v, depth + 1) end
  end
  return result
end

local function readMethod(address, method)
  local ok, value = pcall(component.invoke, address, method)
  if not ok then return nil, tostring(value) end
  return sanitize(value), nil
end

function M.sample()
  local result = {
    timestamp_uptime = require("computer").uptime(),
    equipment = {},
    alarms = {}
  }

  for address, typeName in component.list() do
    local category = classify(typeName)
    if category then
      local item = {
        address = tostring(address),
        type = tostring(typeName),
        category = category,
        readable = 0,
        values = {},
        errors = {}
      }
      local exposedOK, exposed = pcall(component.methods, address)
      if exposedOK and type(exposed) == "table" then
        local allowed = GETTERS[category] or {}
        for _, method in ipairs(allowed) do
          if exposed[method] then
            local value, err = readMethod(address, method)
            if err then
              item.errors[method] = err:sub(1, 160)
            else
              item.values[method] = value
              item.readable = item.readable + 1
            end
          end
        end
      else
        item.errors.methods = "component.methods failed"
      end

      if category == "electric_pump" and item.readable == 0 then
        item.status = "DETECTED_NO_READABLE_API"
      else
        item.status = item.readable > 0 and "READABLE" or "NO_READABLE_GETTERS"
      end

      if category == "oxygen_sealer" then
        if item.values.isEnabled == false then
          result.alarms[#result.alarms + 1] = {
            severity = "WARNING", code = "OXYGEN_SEALER_DISABLED",
            address = item.address
          }
        end
        if item.values.isSealed == false then
          result.alarms[#result.alarms + 1] = {
            severity = "WARNING", code = "ROOM_NOT_REPORTED_SEALED",
            address = item.address
          }
        end
      elseif category == "elite_energy_cube" then
        local stored = item.values.getEnergyStored or item.values.getEUStored or item.values.getRFStored
        local capacity = item.values.getEnergyCapacity or item.values.getEUCapacity or item.values.getRFCapacity
        if type(stored) == "number" and type(capacity) == "number" and capacity > 0 then
          item.values.charge_percent = math.max(0, math.min(100, stored / capacity * 100))
          if item.values.charge_percent < 15 then
            result.alarms[#result.alarms + 1] = {
              severity = "WARNING", code = "ENERGY_STORAGE_LOW",
              address = item.address,
              charge_percent = item.values.charge_percent
            }
          end
        end
      end

      result.equipment[#result.equipment + 1] = item
    end
  end

  table.sort(result.equipment, function(a, b)
    if a.category == b.category then return a.address < b.address end
    return a.category < b.category
  end)
  return result
end

return M
