-- Galactic Station hardware report uploader / HTTP diagnostic
-- OpenOS / OpenComputers Lua.
-- Reads /tmp/main_service_hardware_report.txt and POSTs its raw contents.
-- Paste URLs are public. Do not upload credentials or private configs.

local source = "/tmp/main_service_hardware_report.txt"

local file, fileErr = io.open(source, "rb")
if not file then
  print("Cannot open " .. source .. ": " .. tostring(fileErr))
  print("Run: lua /usr/bin/main_service.lua scan")
  return
end

local data = file:read("*a")
file:close()

if not data or #data == 0 then
  print("The report is empty.")
  return
end

local component = require("component")
local address = component.list("internet")()
if not address then
  print("No Internet Card component is visible to this computer.")
  return
end

print("Report size: " .. tostring(#data) .. " bytes")
print("Opening raw HTTP POST to paste.rs ...")

local internet = component.proxy(address)
local ok, request = pcall(internet.request, "https://paste.rs/", data)
if not ok or not request then
  print("Could not start HTTP request: " .. tostring(request))
  return
end

local connected, connectErr = pcall(function()
  request.finishConnect()
end)
if not connected then
  print("HTTP connection failed: " .. tostring(connectErr))
  pcall(function() request.close() end)
  return
end

local status, message, headers
local responseOK, responseErr = pcall(function()
  status, message, headers = request.response()
end)
if not responseOK then
  print("Could not read HTTP status: " .. tostring(responseErr))
  pcall(function() request.close() end)
  return
end

local body = ""
local bodyOK, bodyErr = pcall(function()
  while true do
    local chunk = request.read(2048)
    if not chunk or #chunk == 0 then break end
    body = body .. chunk
  end
end)
pcall(function() request.close() end)

print("HTTP status: " .. tostring(status) .. " " .. tostring(message))
if body ~= "" then
  print("Server response:")
  print(body)
end

if status and status >= 200 and status < 300 then
  local url = body:match("(https?://%S+)")
  if url then
    print("")
    print("REPORT UPLOADED:")
    print(url)
  else
    print("Upload accepted, but no URL was found in the response.")
  end
else
  print("Upload was not accepted. The report remains at " .. source)
  print("Response read: " .. tostring(bodyOK))
  if not bodyOK then print("Response read error: " .. tostring(bodyErr)) end
end
