-- Galactic Station: Targeted service-equipment API documentation probe
-- OpenComputers / OpenOS Lua 5.2
--
-- SAFE: only reads component.methods() and component.doc().
-- It does NOT invoke any machine getter, setter, transfer, or control method.
--
-- Run:
--   lua /tmp/service_method_docs.lua
--
-- It displays useful getter/status/transfer method signatures and their docs.
-- Full inventory is left in /tmp/main_service_hardware_report.txt.

local component = require("component")

local keywords = {
  "oxygen", "sealer", "pump", "water", "separator",
  "generator", "energy", "electric"
}

local selectedMethods = {
  canExtract=true, canReceive=true,
  getDemandedEnergy=true, getDocs=true,
  getEnergy=true, getEnergyCapacity=true, getEnergyNeeded=true,
  getEnergyStored=true, getEUCapacity=true, getEUOutput=true,
  getEUStored=true, getHydrogen=true, getHydrogenNeeded=true,
  getItemMeta=true, getMaxEnergy=true, getMaxEnergyStored=true,
  getMetadata=true, getOxygen=true, getOxygenTank=true,
  getOutput=true, getRFStored=true, getRFCapacity=true,
  getSinkTier=true, getStoredEnergy=true, getTanks=true,
  getTransferLocations=true, getWater=true, getWaterTank=true,
  isEnabled=true, isSealed=true, isThermalControlEnabled=true,
  isThermalControlWorking=true, setEnabled=true,
  pullFluid=true, pushFluid=true, getFluid=true, getTankInfo=true,
  getFuel=true, getFuelTank=true, getHydrogenTank=true,
  getOxygenLevel=true, getOxygenSupply=true,
  getProduced=true, getProduction=true
}

local function containsKeyword(name)
  local lower = string.lower(name or "")
  for _, word in ipairs(keywords) do
    if lower:find(word, 1, true) then return true end
  end
  return false
end

local function sortedKeys(t)
  local result = {}
  for k in pairs(t or {}) do result[#result + 1] = k end
  table.sort(result)
  return result
end

local entries = {}
for address, typeName in component.list() do
  typeName = tostring(typeName)
  if containsKeyword(typeName) then
    entries[#entries + 1] = {address=tostring(address), typeName=typeName}
  end
end

table.sort(entries, function(a,b)
  if a.typeName == b.typeName then return a.address < b.address end
  return a.typeName < b.typeName
end)

local lines = {
  "GALACTIC STATION - SERVICE EQUIPMENT API DOCS",
  "Metadata-only probe; no machine functions invoked.",
  "Matching components: " .. tostring(#entries),
  string.rep("=", 58)
}

for index, item in ipairs(entries) do
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("[%02d] %s", index, item.typeName)
  lines[#lines + 1] = "Address: " .. item.address

  local ok, methods = pcall(component.methods, item.address)
  if not ok or type(methods) ~= "table" then
    lines[#lines + 1] = "Methods error: " .. tostring(methods)
  else
    local selected = {}
    for methodName in pairs(methods) do
      if selectedMethods[methodName] then selected[#selected + 1] = methodName end
    end
    table.sort(selected)

    if #selected == 0 then
      lines[#lines + 1] = "No selected status/energy/fluid methods exposed."
      lines[#lines + 1] = "All exposed method names: " .. table.concat(sortedKeys(methods), ", ")
    else
      for _, methodName in ipairs(selected) do
        local docOK, documentation = pcall(component.doc, item.address, methodName)
        if not docOK then
          documentation = "[documentation error: " .. tostring(documentation) .. "]"
        elseif documentation == nil or documentation == "" then
          documentation = "[no documentation exposed]"
        end
        documentation = tostring(documentation):gsub("\r", " "):gsub("\n", " ")
        lines[#lines + 1] = methodName .. " : " .. documentation
      end
    end
  end
  lines[#lines + 1] = string.rep("-", 58)
end

local path = "/tmp/main_service_method_docs.txt"
local file, err = io.open(path, "w")
if not file then
  print("Cannot write " .. path .. ": " .. tostring(err))
  return
end
file:write(table.concat(lines, "\n"), "\n")
file:close()

local wrapped = {}
for _, line in ipairs(lines) do
  while #line > 58 do
    local splitAt = line:sub(1,58):match(".*() ")
    if not splitAt or splitAt < 10 then splitAt = 58 end
    wrapped[#wrapped + 1] = line:sub(1,splitAt)
    line = "  " .. line:sub(splitAt + 1):gsub("^%s+", "")
  end
  wrapped[#wrapped + 1] = line
end

print("Saved full docs to " .. path)
local pageSize = 15
local pageCount = math.ceil(#wrapped / pageSize)
local okTerm, term = pcall(require, "term")

for page = 1, pageCount do
  if okTerm and term and term.clear then pcall(term.clear) end
  print("SERVICE API DOCS - PAGE " .. page .. "/" .. pageCount)
  print(string.rep("=", 42))
  local first = (page - 1) * pageSize + 1
  local last = math.min(page * pageSize, #wrapped)
  for i = first, last do print(wrapped[i]) end
  if page < pageCount then
    io.write("\nPress ENTER for next page...")
    io.read()
  end
end

print("Probe complete. No equipment state was changed.")
