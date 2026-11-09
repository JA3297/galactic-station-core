-- Galactic Station Core installer / updater
-- Put this file in the ROOT of your GitHub repository.
-- Edit REPO_BASE to your own raw.githubusercontent.com repository URL.

local REPO_BASE = "https://raw.githubusercontent.com/YOUR_GITHUB_NAME/YOUR_REPOSITORY/main/"
local internet = require("internet")
local filesystem = require("filesystem")

local function say(s) print("[Station Installer] " .. s) end

local function ensureParent(path)
  local parent = path:match("^(.*)/[^/]+$")
  if parent and parent ~= "" then filesystem.makeDirectory(parent) end
end

local function fetch(source, destination)
  say("Downloading " .. source)
  local ok, handle = pcall(internet.request, REPO_BASE .. source)
  if not ok or not handle then
    error("HTTP request failed for " .. source .. ". Check Internet Card/server HTTP settings.")
  end
  ensureParent(destination)
  local file, err = io.open(destination, "wb")
  if not file then error("Cannot write " .. destination .. ": " .. tostring(err)) end
  local success, downloadError = pcall(function()
    for chunk in handle do file:write(chunk) end
  end)
  file:close()
  if not success then
    os.remove(destination)
    error("Download failed for " .. source .. ": " .. tostring(downloadError))
  end
  say("Saved " .. destination)
end

local function save(path, value)
  ensureParent(path)
  local f, err = io.open(path, "w")
  if not f then error("Cannot write " .. path .. ": " .. tostring(err)) end
  f:write(value)
  f:close()
end

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local value = f:read("*a")
  f:close()
  return value
end

local mode = ...
if mode == "update" then
  local role = read("/etc/station/install_role")
  if not role then error("No install record. Run the installer normally first.") end
  if role == "core" then
    fetch("station.lua", "/usr/bin/station.lua")
    fetch("station_rc.lua", "/etc/rc.d/station.lua")
  elseif role == "witness" then
    fetch("witness.lua", "/usr/bin/witness.lua")
    fetch("witness_rc.lua", "/etc/rc.d/witness.lua")
  elseif role == "module" then
    fetch("station_api.lua", "/usr/lib/station_api.lua")
    fetch("module_agent.lua", "/usr/bin/module_agent.lua")
  else
    error("Unknown saved role: " .. tostring(role))
  end
  say("Update complete. Local configuration files were not overwritten.")
  return
end

say("Choose this computer's role:")
print("1 = Core server (one of CORE-A1 through CORE-B8)")
print("2 = Cluster witness")
print("3 = Module computer (optional module agent/API)")
io.write("Selection: ")
local choice = io.read()

filesystem.makeDirectory("/etc/station")
filesystem.makeDirectory("/var/station")
filesystem.makeDirectory("/usr/bin")
filesystem.makeDirectory("/usr/lib")
filesystem.makeDirectory("/etc/rc.d")

-- Keep a local copy so future updates are a one-command operation.
fetch("station-install.lua", "/usr/bin/station-install.lua")

if choice == "1" then
  io.write("Enter this computer's ID (A1 A2 A3 A4 A5 A6 A7 A8 B1 B2 B3 B4 B5 B6 B7 B8): ")
  local id = (io.read() or ""):upper():gsub("%s+", "")
  if not id:match("^[AB][1-8]$") then error("Invalid core ID.") end
  fetch("station.lua", "/usr/bin/station.lua")
  fetch("station_rc.lua", "/etc/rc.d/station.lua")
  fetch("configs/server_" .. id .. ".lua", "/etc/station/node.lua")
  if id == "A5" or id == "B5" then
    fetch("examples/safety_rules.lua", "/etc/station/safety_rules.lua")
  end
  if id == "A8" or id == "B8" then
    fetch("examples/acl.lua", "/etc/station/acl.lua")
  end
  save("/etc/station/install_role", "core")
  say("Core " .. id .. " installed. Enable startup with: rc station enable")

elseif choice == "2" then
  fetch("witness.lua", "/usr/bin/witness.lua")
  fetch("witness_rc.lua", "/etc/rc.d/witness.lua")
  fetch("configs/witness.lua", "/etc/station/witness.lua")
  save("/etc/station/install_role", "witness")
  say("Witness installed. Enable startup with: rc witness enable")

elseif choice == "3" then
  io.write("Enter a unique module ID (example HABITATION-01): ")
  local id = io.read()
  if not id or id == "" then error("A module ID is required.") end
  fetch("station_api.lua", "/usr/lib/station_api.lua")
  fetch("module_agent.lua", "/usr/bin/module_agent.lua")
  save("/etc/station/module.lua",
    "return { module_id = " .. string.format("%q", id) ..
    ', network_id = "GALACTIC-STATION-01" }\n')
  save("/etc/station/install_role", "module")
  say("Module API/agent installed. The agent is optional; run: module_agent")
else
  error("Invalid selection.")
end

say("Installation finished. Review the README before starting the station.")
say("Manual code update later: station-install update")
