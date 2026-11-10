-- Galactic Station management-console installer.
-- Run on the one computer you will use as the central admin terminal.
-- Requires an Internet Card. Does not install any secret or key.

local internet = require("internet")
local filesystem = require("filesystem")
local BASE = "https://raw.githubusercontent.com/JA3297/galactic-station-core/main/"

local function ensure(path)
  filesystem.makeDirectory(filesystem.path(path))
end

local function fetch(source, destination)
  print("Downloading " .. source)
  local ok, handle = pcall(internet.request, BASE .. source)
  if not ok or not handle then error("HTTP request failed for " .. source .. ": " .. tostring(handle)) end
  ensure(destination)
  local f, err = io.open(destination, "wb")
  if not f then error("Cannot write " .. destination .. ": " .. tostring(err)) end
  local good, reason = pcall(function()
    for chunk in handle do f:write(chunk) end
  end)
  f:close()
  if not good then os.remove(destination); error("Download failed: " .. tostring(reason)) end
  print("Installed " .. destination)
end

filesystem.makeDirectory("/etc/station")
filesystem.makeDirectory("/usr/bin")
filesystem.makeDirectory("/usr/lib")
filesystem.makeDirectory("/var/station")

fetch("admin_crypto.lua", "/usr/lib/admin_crypto.lua")
fetch("station_admin.lua", "/usr/bin/station_admin.lua")
fetch("admin_key_setup.lua", "/usr/bin/admin_key_setup.lua")

print("")
print("Management console files installed.")
print("Next: create /etc/station/remote_admin.key, then install the same key")
print("and remote_admin_agent service on each managed computer.")
print("Launch the console with: lua /usr/bin/station_admin.lua")
