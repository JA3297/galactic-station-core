-- Galactic Station remote-management bootstrap installer.
-- Run once on EACH managed computer. Run on the admin computer only if it is also a managed station node.
-- Requires an Internet Card for this initial bootstrap.
-- The shared secret is entered locally and is never downloaded from GitHub.

local internet = require("internet")
local filesystem = require("filesystem")

local BASE = "https://raw.githubusercontent.com/JA3297/galactic-station-core/main/"

local function fetch(source, destination)
  print("Downloading " .. source)
  local ok, handle = pcall(internet.request, BASE .. source)
  if not ok or not handle then error("Download failed for " .. source .. ": " .. tostring(handle)) end
  local parent = filesystem.path(destination)
  if parent then filesystem.makeDirectory(parent) end
  local f, err = io.open(destination, "wb")
  if not f then error("Cannot write " .. destination .. ": " .. tostring(err)) end
  local good, reason = pcall(function()
    for chunk in handle do f:write(chunk) end
  end)
  f:close()
  if not good then os.remove(destination); error("Download failed: " .. tostring(reason)) end
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local v = f:read("*a"); f:close(); return v
end

filesystem.makeDirectory("/etc/station")
filesystem.makeDirectory("/var/station")
filesystem.makeDirectory("/usr/lib")
filesystem.makeDirectory("/etc/rc.d")

fetch("admin_crypto.lua", "/usr/lib/admin_crypto.lua")
fetch("remote_admin_agent.lua", "/usr/lib/remote_admin_agent.lua")
fetch("remote_admin_rc.lua", "/etc/rc.d/remote_admin.lua")
fetch("station_logger.lua", "/usr/lib/station_logger.lua")

local key = read("/etc/station/remote_admin.key")
if key then key = key:gsub("[\r\n]+$", "") end
local keepExisting = key and #key >= 64
if keepExisting then
  print("")
  print("A remote-admin key already exists on this computer.")
  io.write("Keep the existing key? [Y/n]: ")
  local answer = string.lower(io.read("*l") or "y")
  keepExisting = answer ~= "n" and answer ~= "no"
end

if not keepExisting then
  print("")
  print("Enter the shared 64+ character secret used by the management computer.")
  io.write("Paste secret: ")
  local first = io.read("*l")
  io.write("Paste secret again: ")
  local second = io.read("*l")
  if not first or #first < 64 or first ~= second then
    error("Secret missing, too short, or confirmation did not match.")
  end
  local f, err = io.open("/etc/station/remote_admin.key", "wb")
  if not f then error("Cannot save key: " .. tostring(err)) end
  f:write(first, "\n"); f:close()
else
  print("Existing remote-admin key preserved.")
end
local config
local ok, value = pcall(dofile, "/etc/station/node.lua")
if ok and type(value) == "table" then config = value end

if config and config.role == "archive" and config.pair_id == "PAIR-DATA" then
  fetch("station_log_collector.lua", "/usr/lib/station_log_collector.lua")
  fetch("station_log_collector_rc.lua", "/etc/rc.d/station_log_collector.lua")
  print("Archive log collector installed for " .. tostring(config.node_id))
elseif config and config.module_id then
  fetch("station_api.lua", "/usr/lib/station_api.lua")
  if config.module_id == "MAIN-SERVICE-01" then
    fetch("main_service_monitor.lua", "/usr/bin/main_service_monitor.lua")
    fetch("main_service_monitor_rc.lua", "/etc/rc.d/main_service_monitor.lua")
    print("Main Service life-support monitor installed.")
    print("Do not run module_agent simultaneously with the Main Service monitor.")
  else
    fetch("module_agent.lua", "/usr/bin/module_agent.lua")
    print("Optional module_agent installed; enable only if no other local program pulls modem events.")
  end
end

print("")
print("Remote agent files installed.")
print("Start and enable the agent now:")
print("  rc remote_admin start")
print("  rc remote_admin enable")
if config and config.role == "archive" then
  print("Start and enable the archive collector:")
  print("  rc station_log_collector start")
  print("  rc station_log_collector enable")
elseif config and config.module_id == "MAIN-SERVICE-01" then
  print("Start and enable the Main Service monitor:")
  print("  rc main_service_monitor start")
  print("  rc main_service_monitor enable")
end
print("Restart existing station/witness processes during a maintenance window to load the structured logger.")
print("Network port: 45822 | Log port: 45823")
print("HMAC authentication enabled; modem packets are not encrypted.")
