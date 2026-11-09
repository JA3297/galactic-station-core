-- Galactic Station compact hardware report viewer
-- Reads the existing scan report; does not rescan or call any machine methods.
-- Run: lua /tmp/show_hardware_summary.lua

local source = "/tmp/main_service_hardware_report.txt"
local input, err = io.open(source, "r")
if not input then
  print("Cannot open " .. source .. ": " .. tostring(err))
  print("The original report has not been modified.")
  return
end

local sections = {}
local header = {}
local current = nil

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function finishSection()
  if current then sections[#sections + 1] = current end
  current = nil
end

for line in input:lines() do
  if line:match("^%[%d+%] TYPE:") then
    finishSection()
    current = { typeLine = trim(line), category = "", address = "", methods = {} }
  elseif not current then
    header[#header + 1] = line
  else
    local category = line:match("^%s+CATEGORY:%s*(.*)$")
    if category then current.category = trim(category) end

    local address = line:match("^%s+ADDRESS:%s*(.*)$")
    if address then current.address = trim(address) end

    local method = line:match("^%s+%-%s+([^:]+)%s*:")
    if method then current.methods[#current.methods + 1] = trim(method) end

    local noMethods = line:match("^%s+METHODS:%s*(.*)$")
    if noMethods and noMethods ~= "[none exposed]" then
      current.methodsNote = trim(noMethods)
    end

    local methodError = line:match("^%s+METHODS ERROR:%s*(.*)$")
    if methodError then current.methodsNote = "ERROR: " .. trim(methodError) end
  end
end
finishSection()
input:close()

local out = {}
out[#out + 1] = "GALACTIC STATION - COMPACT HARDWARE INVENTORY"
out[#out + 1] = "Original report: " .. source
out[#out + 1] = "Components found: " .. tostring(#sections)
out[#out + 1] = ""
for _, line in ipairs(header) do
  if line:match("^  [%w_%-]+%s+%d+") or line:match("^Controller version:") or
     line:match("^Computer uptime:") or line:match("^Total exposed components:") then
    out[#out + 1] = line
  end
end
out[#out + 1] = ""
out[#out + 1] = "COMPONENTS (method names only; no methods were executed)"
out[#out + 1] = ""

for i, item in ipairs(sections) do
  out[#out + 1] = item.typeLine
  out[#out + 1] = "  CATEGORY: " .. item.category
  out[#out + 1] = "  ADDRESS: " .. item.address

  if #item.methods == 0 then
    out[#out + 1] = "  METHODS: " .. (item.methodsNote or "[none listed]")
  else
    local line = "  METHODS: "
    for _, name in ipairs(item.methods) do
      if #line + #name + 2 > 76 then
        out[#out + 1] = line
        line = "           "
      end
      if line:sub(-1) ~= " " then line = line .. ", " end
      line = line .. name
    end
    out[#out + 1] = line
  end
  out[#out + 1] = ""
end

local result = table.concat(out, "\n") .. "\n"
local output, writeErr = io.open("/tmp/main_service_compact.txt", "w")
if not output then
  print("Could not write compact report: " .. tostring(writeErr))
  return
end
output:write(result)
output:close()

local pages = {}
local page = {}
for line in result:gmatch("([^\n]*)\n") do
  page[#page + 1] = line
  if #page >= 17 then
    pages[#pages + 1] = page
    page = {}
  end
end
if #page > 0 then pages[#pages + 1] = page end

print("Compact report created: /tmp/main_service_compact.txt")
print("Original report preserved: " .. source)
print("Components: " .. tostring(#sections) .. " | Pages: " .. tostring(#pages))
print("Method documentation was omitted; method names only.")
print("Press ENTER for each page. Photograph each page and send it here.")

for index, lines in ipairs(pages) do
  print("")
  print("========== PAGE " .. index .. " / " .. #pages .. " ==========")
  for _, line in ipairs(lines) do print(line) end
  if index < #pages then
    io.write("-- press ENTER for next page -- ")
    io.read()
  end
end

print("")
print("End of report. Nothing was changed on connected machines.")
