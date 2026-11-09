-- Galactic Station: Targeted machine API documentation probe
-- Safe discovery only: calls component.methods and component.doc.
-- DOES NOT invoke any machine getter, setter, transfer, or control method.
--
-- Usage:
--   lua /tmp/service_method_docs.lua
--
-- Output:
--   /tmp/main_service_method_docs.txt

local component = require("component")
local keywords = {
  "oxygen", "sealer", "pump", "water", "separator",
  "generator", "energy", "electric"
}

local function matches(typeName)
  local lower = string.lower(typeName or "")
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
  if matches(typeName) then
    entries[#entries + 1] = {
      address = tostring(address),
      typeName = typeName
    }
  end
end

table.sort(entries, function(a, b)
  if a.typeName == b.typeName then return a.address < b.address end
  return a.typeName < b.typeName
end)

local lines = {
  "GALACTIC STATION - SERVICE EQUIPMENT API DOCUMENTATION",
  "Safe metadata probe. No machine methods were invoked.",
  "Matching components: " .. tostring(#entries),
  string.rep("=", 64)
}

for index, item in ipairs(entries) do
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("[%02d] TYPE: %s", index, item.typeName)
  lines[#lines + 1] = "ADDRESS: " .. item.address

  local ok, methods = pcall(component.methods, item.address)
  if not ok or type(methods) ~= "table" then
    lines[#lines + 1] = "METHOD LIST ERROR: " .. tostring(methods)
  else
    for _, methodName in ipairs(sortedKeys(methods)) do
      local docOK, documentation = pcall(component.doc, item.address, methodName)
      if not docOK then
        documentation = "[documentation error: " .. tostring(documentation) .. "]"
      elseif documentation == nil or documentation == "" then
        documentation = "[no documentation exposed]"
      end
      documentation = tostring(documentation):gsub("\r", " "):gsub("\n", " ")
      lines[#lines + 1] = "  " .. tostring(methodName) .. " : " .. documentation
    end
  end
  lines[#lines + 1] = string.rep("-", 64)
end

if #entries == 0 then
  lines[#lines + 1] = "No matching components found."
end

local outputPath = "/tmp/main_service_method_docs.txt"
local file, err = io.open(outputPath, "w")
if not file then
  print("Cannot write report: " .. tostring(err))
  return
end
file:write(table.concat(lines, "\n"), "\n")
file:close()

local width = 58
local wrapped = {}
for _, line in ipairs(lines) do
  if #line <= width then
    wrapped[#wrapped + 1] = line
  else
    local remaining = line
    while #remaining > width do
      local splitAt = width
      local space = remaining:sub(1, width):match(".*() ")
      if space and space > 12 then splitAt = space end
      wrapped[#wrapped + 1] = remaining:sub(1, splitAt)
      remaining = "    " .. remaining:sub(splitAt + 1):gsub("^%s+", "")
    end
    if #remaining > 0 then wrapped[#wrapped + 1] = remaining end
  end
end

print("Saved full documentation to " .. outputPath)
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

print("Documentation probe complete. No equipment was controlled.")
