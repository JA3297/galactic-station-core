-- Galactic Station blank-slate bootstrap installer
-- Version: 1.0.0
-- Target: OpenComputers + OpenOS / LuaJ
--
-- This is the ONE installer for a fresh Galactic Station deployment.
-- Run it after OpenOS has been installed onto a writable hard drive.
--
-- Roles:
--   Core A1-B8
--   Witness
--   Module (including MAIN-SERVICE-01)
--   Standalone management console
--
-- This installer never formats a drive or deletes user data. Existing
-- configuration/program files are preserved as .pre-gs-backup[.N] copies.
-- Secrets are never downloaded from GitHub and are never written to GitHub.

local filesystem = require("filesystem")
local internet = require("internet")

local BASE = "https://raw.githubusercontent.com/JA3297/galactic-station-core/main/"
local DEFAULT_NETWORK = "GALACTIC-STATION-01"
local DEFAULT_REPO = "JA3297/galactic-station-core"
local VERSION = "1.0.0"

local function say(message) print("[GALACTIC INSTALLER] " .. tostring(message)) end
local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function ask(prompt, default)
  io.write(prompt)
  if default and default ~= "" then io.write(" [" .. default .. "]") end
  io.write(": ")
  local value = io.read("*l")
  value = trim(value)
  if value == "" then return default end
  return value
end

local function yesNo(prompt, defaultYes)
  local default = defaultYes and "Y/n" or "y/N"
  local value = string.lower(ask(prompt .. " (" .. default .. ")", defaultYes and "y" or "n"))
  return value == "y" or value == "yes"
end

local function ensureDirectory(path)
  if not path or path == "" or path == "/" then return true end
  local ok, reason = filesystem.makeDirectory(path)
  if not ok and not filesystem.isDirectory(path) then
    return false, tostring(reason or "could not create " .. path)
  end
  return true
end

local function backupExisting(path)
  if not filesystem.exists(path) then return nil end
  local backup = path .. ".pre-gs-backup"
  local suffix = 1
  while filesystem.exists(backup) do
    suffix = suffix + 1
    backup = path .. ".pre-gs-backup." .. tostring(suffix)
  end
  local ok, reason = os.rename(path, backup)
  if not ok then error("Could not preserve existing " .. path .. ": " .. tostring(reason)) end
  return backup
end

local function writeFile(path, data, preserveExisting)
  local parent = filesystem.path(path)
  local ok, reason = ensureDirectory(parent)
  if not ok then error(reason) end

  local temporary = path .. ".gs-install-tmp"
  os.remove(temporary)
  local file, openErr = io.open(temporary, "wb")
  if not file then error("Cannot write " .. temporary .. ": " .. tostring(openErr)) end
  local writeOK, writeErr = pcall(function() file:write(data) end)
  file:close()
  if not writeOK then
    os.remove(temporary)
    error("Write failed for " .. path .. ": " .. tostring(writeErr))
  end

  if filesystem.exists(path) then
    if preserveExisting then backupExisting(path) else os.remove(path) end
  end
  local moved, moveErr = os.rename(temporary, path)
  if not moved then
    os.remove(temporary)
    error("Could not install " .. path .. ": " .. tostring(moveErr))
  end
end

local function download(source)
  say("Downloading " .. source)
  local ok, handle = pcall(internet.request, BASE .. source)
  if not ok or not handle then
    error("HTTP request failed for " .. source .. ": " .. tostring(handle))
  end
  local chunks = {}
  local good, reason = pcall(function()
    for chunk in handle do chunks[#chunks + 1] = chunk end
  end)
  if not good then error("Download failed for " .. source .. ": " .. tostring(reason)) end
  local data = table.concat(chunks)
  if #data == 0 then error("Downloaded empty file: " .. source) end
  return data
end

local function installRemote(source, destination)
  local data = download(source)
  writeFile(destination, data, true)
  say("Installed " .. destination)
end

local function installText(destination, data, preserveExisting)
  writeFile(destination, data, preserveExisting)
  say("Created " .. destination)
end

local function installCommon()
  ensureDirectory("/etc/station")
  ensureDirectory("/etc/rc.d")
  ensureDirectory("/usr/bin")
  ensureDirectory("/usr/lib")
  ensureDirectory("/var/station")

  installRemote("admin_crypto.lua", "/usr/lib/admin_crypto.lua")
  installRemote("remote_admin_agent.lua", "/usr/lib/remote_admin_agent.lua")
  installRemote("remote_admin_rc.lua", "/etc/rc.d/remote_admin.lua")
  installRemote("station_logger.lua", "/usr/lib/station_logger.lua")
end

local function configureKey()
  local keyPath = "/etc/station/remote_admin.key"
  local existing = ""
  local old = io.open(keyPath, "rb")
  if old then existing = old:read("*a") or ""; old:close() end
  existing = existing:gsub("[\r\n]+$", "")

  if #existing >= 64 then
    say("A remote-administration key already exists.")
    if yesNo("Keep the existing key", true) then
      return
    end
  end

  print("")
  print("Enter the SAME high-entropy 64+ character secret on every managed computer.")
  print("Use a password manager to generate it. Never send it to GitHub or ChatGPT.")
  local first = ask("Shared management secret")
  local second = ask("Confirm management secret")
  if not first or #first < 64 or first ~= second then
    error("Secret confirmation failed or secret is shorter than 64 characters.")
  end
  installText(keyPath, first .. "\n", false)
end

local function validId(value)
  return type(value) == "string" and value:match("^[A-Z][A-Z0-9_-]*$") ~= nil
end

local function installCore()
  print("")
  print("Valid core IDs: A1-A8, B1-B8")
  local id = string.upper(ask("Core ID (for example A4)"))
  if not id:match("^[AB][1-8]$") then error("Invalid core ID: " .. tostring(id)) end

  installCommon()
  installRemote("station.lua", "/usr/bin/station.lua")
  installRemote("station_rc.lua", "/etc/rc.d/station.lua")
  installRemote("configs/server_" .. id .. ".lua", "/etc/station/node.lua")

  if id == "A5" or id == "B5" then
    installRemote("examples/safety_rules.lua", "/etc/station/safety_rules.lua")
  end
  if id == "A8" or id == "B8" then
    installRemote("examples/acl.lua", "/etc/station/acl.lua")
  end

  local role = (id == "A4" or id == "B4") and "archive" or "core"
  if role == "archive" then
    installRemote("station_log_collector.lua", "/usr/lib/station_log_collector.lua")
    installRemote("station_log_collector_rc.lua", "/etc/rc.d/station_log_collector.lua")
  end

  configureKey()
  return "CORE-" .. id, role
end

local function installWitness()
  installCommon()
  installRemote("witness.lua", "/usr/bin/witness.lua")
  installRemote("witness_rc.lua", "/etc/rc.d/witness.lua")
  installRemote("configs/witness.lua", "/etc/station/witness.lua")
  configureKey()
  return "STATION-WITNESS", "witness"
end

local function installModule()
  installCommon()
  local moduleId = string.upper(ask("Unique module ID (example MAIN-SERVICE-01)"))
  if not validId(moduleId) then error("Invalid module ID. Use A-Z, 0-9, underscore, and hyphen.") end
  local networkId = ask("Station network ID", DEFAULT_NETWORK)
  local moduleConfig = "return {\n" ..
    "  module_id = " .. string.format("%q", moduleId) .. ",\n" ..
    "  network_id = " .. string.format("%q", networkId) .. "\n}\n"
  installText("/etc/station/module.lua", moduleConfig, true)
  installRemote("station_api.lua", "/usr/lib/station_api.lua")

  if moduleId == "MAIN-SERVICE-01" then
    installRemote("main_service_monitor.lua", "/usr/bin/main_service_monitor.lua")
    installRemote("main_service_monitor_rc.lua", "/etc/rc.d/main_service_monitor.lua")
  else
    installRemote("module_agent.lua", "/usr/bin/module_agent.lua")
    installRemote("module_agent_rc.lua", "/etc/rc.d/module_agent.lua")
  end

  configureKey()
  return moduleId, moduleId == "MAIN-SERVICE-01" and "main_service" or "module"
end

local function installManagement()
  ensureDirectory("/etc/station")
  ensureDirectory("/usr/bin")
  ensureDirectory("/usr/lib")
  ensureDirectory("/var/station")
  installRemote("admin_crypto.lua", "/usr/lib/admin_crypto.lua")
  installRemote("admin_crypto_test.lua", "/usr/bin/admin_crypto_test.lua")
  installRemote("station_admin.lua", "/usr/bin/station_admin.lua")
  installRemote("admin_key_setup.lua", "/usr/bin/admin_key_setup.lua")

  local networkId = ask("Station network ID", DEFAULT_NETWORK)
  local adminId = string.upper(ask("Management client ID", "STATION-ADMIN-01"))
  if not validId(adminId) then error("Invalid management client ID.") end
  local config = "return {\n" ..
    "  network_id = " .. string.format("%q", networkId) .. ",\n" ..
    "  admin_id = " .. string.format("%q", adminId) .. "\n}\n"
  installText("/etc/station/admin.lua", config, true)
  configureKey()
  return adminId, "management"
end

local function offerManagementConsole()
  if yesNo("Also install the management console on this computer", false) then
    installRemote("admin_crypto_test.lua", "/usr/bin/admin_crypto_test.lua")
    installRemote("station_admin.lua", "/usr/bin/station_admin.lua")
    installRemote("admin_key_setup.lua", "/usr/bin/admin_key_setup.lua")
  end
end

local function printNextSteps(nodeId, role)
  print("")
  print("============================================================")
  print(" INSTALLATION COMPLETE")
  print("============================================================")
  print("Computer ID: " .. tostring(nodeId))
  print("Installed profile: " .. tostring(role))
  print("")

  if role == "core" or role == "archive" then
    print("Start station runtime:")
    print("  rc station start")
    print("  rc station enable")
  elseif role == "witness" then
    print("Start cluster witness:")
    print("  rc witness start")
    print("  rc witness enable")
  elseif role == "module" then
    print("Start module communications agent:")
    print("  rc module_agent start")
    print("  rc module_agent enable")
  elseif role == "main_service" then
    print("Start Main Service monitor:")
    print("  rc main_service_monitor start")
    print("  rc main_service_monitor enable")
  elseif role == "management" then
    print("Run cryptography self-test:")
    print("  lua /usr/bin/admin_crypto_test.lua")
    print("Launch management console:")
    print("  lua /usr/bin/station_admin.lua")
  end

  if role == "archive" then
    print("")
    print("Also start the archive log collector:")
    print("  rc station_log_collector start")
    print("  rc station_log_collector enable")
  end

  if role ~= "management" then
    print("")
    print("Start remote administration:")
    print("  rc remote_admin start")
    print("  rc remote_admin enable")
  end
  print("")
  print("No filesystems were formatted. Existing files were backed up where replaced.")
  print("============================================================")
end

local function main()
  print("============================================================")
  print(" GALACTIC STATION | BLANK-SLATE INSTALLER")
  print(" Version " .. VERSION)
  print("============================================================")
  print("This installs Galactic Station software and role configuration.")
  print("It does NOT format drives or erase user data.")
  print("OpenOS itself must already be installed on a writable hard drive.")
  print("")

  local readOnly = false
  local readOnlyOK, readOnlyValue = pcall(filesystem.isReadOnly, "/")
  if readOnlyOK then readOnly = readOnlyValue == true end
  if readOnly then
    print("ERROR: The current root filesystem is read-only.")
    print("Boot from the OpenOS floppy and run: install")
    print("Install OpenOS onto the computer's hard drive, reboot, and run this installer again.")
    return
  end

  print("Choose this computer's role:")
  print("1 = Core server (CORE-A1 through CORE-B8)")
  print("2 = Cluster witness")
  print("3 = Module computer (example MAIN-SERVICE-01)")
  print("4 = Standalone management console")
  local choice = ask("Selection")

  local nodeId, role
  if choice == "1" then
    nodeId, role = installCore()
    offerManagementConsole()
  elseif choice == "2" then
    nodeId, role = installWitness()
  elseif choice == "3" then
    nodeId, role = installModule()
    offerManagementConsole()
  elseif choice == "4" then
    nodeId, role = installManagement()
  else
    error("Invalid role selection.")
  end

  printNextSteps(nodeId, role)
end

local ok, err = pcall(main)
if not ok then
  print("")
  print("INSTALLATION FAILED: " .. tostring(err))
  print("Previously installed files were retained or backed up when possible.")
end
