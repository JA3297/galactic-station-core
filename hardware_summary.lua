-- Galactic Station compact hardware report viewer
-- OpenComputers / OpenOS Lua 5.2
-- Reads the existing detailed report and displays only component identity
-- and method names. Does not call any machine methods.
--
-- Usage:
--   lua /tmp/hardware_summary.lua
--
-- Input:
--   /tmp/main_service_hardware_report.txt

local inputPath = "/tmp/main_service_hardware_report.txt"
local input, err = io.open(inputPath, "r")
if not input then
  print("Cannot open " .. inputPath .. ": " .. tostring(err))
  print("Run the hardware scan first:")
  print("  lua /usr/bin/main_service.lua scan")
  return
end

local report = input:read("*a")
input:close()

local counts = {}
local components = {}
local current = nil

for line in report:gmatch("[^\r\n]+") do
  local number, typeName = line:match("^%[(%d+)%] TYPE: (.+)$")
  if number then
    current = {
      number = tonumber(number),
      typeName = typeName,
      category = "UNKNOWN",
      address = "unknown",
      methods = {}
    }
    components[#components + 1] = current
  elseif current then
    local category = line:match("^%s+CATEGORY: (.+)$")
    if category then current.category = category end

    local address = line:match("^%s+ADDRESS: (.+)$")
    if address then current.address = address end

    local method = line:match("^%s+%- ([%w_]+) :")
    if method then current.methods[#current.methods + 1] = method end
  end
end

if #components == 0 then
  print("No component entries were found in the report.")
  print("The report may be from an older format or empty.")
  return
end

local lines = {}
lines[#lines + 1] = "GALACTIC STATION - MAIN SERVICE HARDWARE SUMMARY"
lines[#lines + 1] = "Components found: " .. tostring(#components)
lines[#lines + 1] = "Method names only; no machine methods were invoked."
lines[#lines + 1] = string.rep("=", 68)

for _, item in ipairs(components) do
  counts[item.category] = (counts[item.category] or 0) + 1
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("[%02d] %s", item.number, item.typeName)
  lines[#lines + 1] = "Category: " .. item.category
  lines[#lines + 1] = "Address: " .. item.address
  if #item.methods == 0 then
    lines[#lines + 1] = "Methods: (none reported)"
  else
    lines[#lines + 1] = "Methods:"
    local row = "  "
    for _, name in ipairs(item.methods) do
      local piece = name .. ", "
      if #row + #piece > 66 then
        lines[#lines + 1] = row:gsub(", $", "")
        row = "  " .. piece
      else
        row = row .. piece
      end
    end
    if #row > 2 then lines[#lines + 1] = row:gsub(", $", "") end
  end
  lines[#lines + 1] = string.rep("-", 68)
end

lines[#lines + 1] = ""
lines[#lines + 1] = "CATEGORY TOTALS"
for category, count in pairs(counts) do
  lines[#lines + 1] = string.format("  %-36s %d", category, count)
end
lines[#lines + 1] = ""
lines[#lines + 1] = "END OF SUMMARY"

local outputPath = "/tmp/main_service_hardware_summary.txt"
local output, outErr = io.open(outputPath, "w")
if output then
  output:write(table.concat(lines, "\n"), "\n")
  output:close()
  print("Saved compact summary to " .. outputPath)
else
  print("Could not save summary: " .. tostring(outErr))
end

local pageSize = 16
local pages = math.ceil(#lines / pageSize)
local termOK, terminal = pcall(require, "term")

for page = 1, pages do
  if termOK and terminal and terminal.clear then
    pcall(terminal.clear)
  end
  print("HARDWARE SUMMARY - PAGE " .. page .. "/" .. pages)
  print(string.rep("=", 42))
  local first = (page - 1) * pageSize + 1
  local last = math.min(page * pageSize, #lines)
  for i = first, last do print(lines[i]) end

  if page < pages then
    io.write("\nPress ENTER for next page...")
    io.read()
  end
end

print("")
print("Summary complete. File: " .. outputPath)
