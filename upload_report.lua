-- Galactic Station hardware report uploader
-- OpenOS / OpenComputers Lua
-- Uploads /tmp/main_service_hardware_report.txt to paste.rs.
-- The resulting paste URL is public. Do not use for credentials or secrets.

local source = "/tmp/main_service_hardware_report.txt"
local f, err = io.open(source, "r")
if not f then
  print("Could not open report: " .. tostring(err))
  print("Run the hardware scan first:")
  print("  lua /usr/bin/main_service.lua scan")
  return
end

local data = f:read("*a")
f:close()

if not data or data == "" then
  print("The report file is empty.")
  return
end

print("Report size: " .. tostring(#data) .. " bytes")
print("Uploading as raw POST data...")

local ok, request = pcall(function()
  return require("internet").request(
    "https://paste.rs/",
    data,
    {
      ["Content-Type"] = "application/octet-stream",
      ["Accept"] = "text/plain"
    },
    "POST"
  )
end)

if not ok or not request then
  print("Upload request failed: " .. tostring(request))
  print("Check Internet Card HTTP access and server settings.")
  return
end

local response = ""
local readOK, readErr = pcall(function()
  for chunk in request do
    response = response .. chunk
  end
end)

if not readOK then
  print("The paste service rejected the upload: " .. tostring(readErr))
  print("The report remains saved at " .. source)
  print("Fallback: run 'cat " .. source .. "' and send terminal screenshots.")
  return
end

response = response:gsub("^%s+", ""):gsub("%s+$", "")
if response:match("^https?://") then
  print("")
  print("REPORT UPLOADED SUCCESSFULLY")
  print(response)
else
  print("Paste service response:")
  print(response)
  print("The report remains saved at " .. source)
end
