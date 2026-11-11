-- Galactic Station v4 unified three-server bootstrap.
-- OpenComputers / OpenOS. Run after OpenOS is installed on writable HDD.
--
-- Profiles:
--   1 PRIMARY   -> GS-CORE-01
--   2 STANDBY   -> GS-CORE-02
--   3 OPERATIONS -> STATION-WITNESS (witness + manager + log archive)
--
-- No disk formatting. Existing managed files are preserved as .v3-backup.
-- All three servers use one locally provisioned high-entropy management key.
-- The key is NEVER downloaded from GitHub or written to the repository.

local filesystem = require("filesystem")
local internet = require("internet")
local component = require("component")

local BASE = "https://raw.githubusercontent.com/JA3297/galactic-station-core/main/"
local DEFAULT_NETWORK = "GALACTIC-STATION-01"
local VERSION = "4.0.0"

local function say(message) print("[GS V4 INSTALLER] " .. tostring(message)) end
local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function ask(prompt, default)
  io.write(prompt)
  if default and default ~= "" then io.write(" [" .. default .. "]") end
  io.write(": ")
  local value = trim(io.read("*l"))
  if value == "" then return default end
  return value
end

local function yesNo(prompt, defaultYes)
  local answer = string.lower(ask(prompt .. (defaultYes and " (Y/n)" or " (y/N)"), defaultYes and "y" or "n"))
  if answer == "" then return defaultYes end
  return answer == "y" or answer == "yes"
end

local function ensureDirectory(path)
  if not path or path == "" or path == "/" then return true end
  local ok, reason = filesystem.makeDirectory(path)
  if not ok and not filesystem.isDirectory(path) then
    error("Cannot create directory " .. path .. ": " .. tostring(reason))
  end
  return true
end

local function backupExisting(path)
  if not filesystem.exists(path) then return end
  local backup = path .. ".v3-backup"
  local suffix = 1
  while filesystem.exists(backup) do
    suffix = suffix + 1
    backup = path .. ".v3-backup." .. tostring(suffix)
  end
  local ok, reason = os.rename(path, backup)
  if not ok then error("Cannot preserve existing " .. path .. ": " .. tostring(reason)) end
  say("Preserved previous file as " .. backup)
end

local function writeFile(path, data, backup)
  local parent = filesystem.path(path)
  ensureDirectory(parent)
  local temp = path .. ".v4-install-tmp"
  os.remove(temp)
  local file, err = io.open(temp, "wb")
  if not file then error("Cannot write " .. temp .. ": " .. tostring(err)) end
  local ok, writeErr = pcall(function() file:write(data) end)
  file:close()
  if not ok then os.remove(temp); error("Write failed: " .. tostring(writeErr)) end

  if filesystem.exists(path) then
    if backup then backupExisting(path) else os.remove(path) end
  end
  local moved, moveErr = os.rename(temp, path)
  if not moved then os.remove(temp); error("Cannot install " .. path .. ": " .. tostring(moveErr)) end
  say("Installed " .. path)
end

local function download(source)
  say("Downloading " .. source)
  local ok, handle = pcall(internet.request, BASE .. source)
  if not ok or not handle then error("HTTP request failed for " .. source .. ": " .. tostring(handle)) end
  local chunks = {}
  local readOK, readErr = pcall(function()
    for chunk in handle do chunks[#chunks + 1] = chunk end
  end)
  if not readOK then error("Download failed for " .. source .. ": " .. tostring(readErr)) end
  local data = table.concat(chunks)
  if #data == 0 then error("Downloaded empty file: " .. source) end
  return data
end

local function installRemote(source, destination)
  writeFile(destination, download(source), true)
end

local function installText(destination, data, backup)
  writeFile(destination, data, backup)
end

local function hex(data)
  return (data:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function readAll(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local value = file:read("*a")
  file:close()
  return value
end

local function provisionKey(isOperations)
  local path = "/etc/station/remote_admin.key"
  local existing = readAll(path)
  if existing then existing = existing:gsub("[\r\n]+$", "") end

  if existing and #existing >= 64 then
    if yesNo("Keep existing management key", true) then return end
  end

  local key = nil
  if isOperations and yesNo("Generate a fresh 256-bit key using the Tier 3 Data Card", true) then
    for address in component.list("data", true) do
      local card = component.proxy(address)
      if card.random then
        local ok, bytes = pcall(card.random, 32)
        if ok and type(bytes) == "string" and #bytes == 32 then
          key = hex(bytes)
          break
        end
      end
    end
    if not key then
      say("No usable Data Card random() method found; enter a high-entropy key manually.")
    end
  end

  if not key then
    print("")
    print("Enter the SAME 64+ character secret on all three servers.")
    print("Use a password manager or Data Card. Never photograph or share it.")
    local first = ask("Management key")
    local second = ask("Confirm management key")
    if not first or #first < 64 or first ~= second then
      error("Key is too short or the two entries do not match.")
    end
    key = first
  end

  installText(path, key .. "\n", false)
  if isOperations then
    print("")
    print("NEW MANAGEMENT KEY CREATED.")
    print("Record it securely for the primary and standby installers.")
    print("Do NOT send it to ChatGPT, GitHub, or a screenshot.")
    print(key)
    print("")
  end
end

local function installCommon(networkId, isOperations)
  for _, dir in ipairs({"/etc/station", "/etc/rc.d", "/usr/bin", "/usr/lib", "/var/station"}) do
    ensureDirectory(dir)
  end

  installRemote("admin_crypto.lua", "/usr/lib/admin_crypto.lua")
  installRemote("admin_crypto_test.lua", "/usr/bin/admin_crypto_test.lua")
  installRemote("remote_admin_agent.lua", "/usr/lib/remote_admin_agent.lua")
  installRemote("remote_admin_rc.lua", "/etc/rc.d/remote_admin.lua")
  installRemote("remote_admin_diagnose.lua", "/usr/bin/remote_admin_diagnose.lua")
  installRemote("station_logger.lua", "/usr/lib/station_logger.lua")
  installRemote("station_admin.lua", "/usr/bin/station_admin.lua")
  installRemote("admin_key_setup.lua", "/usr/bin/admin_key_setup.lua")

  provisionKey(isOperations)
end

local function installCore(primary, networkId)
  installCommon(networkId, false)
  installRemote("v4/station_core.lua", "/usr/bin/station.lua")
  installRemote("v4/station_rc.lua", "/etc/rc.d/station.lua")
  installRemote(primary and "v4/configs/core_primary.lua" or "v4/configs/core_standby.lua", "/etc/station/node.lua")
  installRemote("examples/safety_rules.lua", "/etc/station/safety_rules.lua")
  installRemote("examples/acl.lua", "/etc/station/acl.lua")
  print("")
  print("Core profile: " .. (primary and "PRIMARY / GS-CORE-01" or "STANDBY / GS-CORE-02"))
  print("Start after all three servers are installed:")
  print("  rc remote_admin start")
  print("  rc remote_admin enable")
  print("  rc station start")
  print("  rc station enable")
end

local function installOperations(networkId)
  installCommon(networkId, true)
  installRemote("v4/witness.lua", "/usr/bin/witness.lua")
  installRemote("v4/witness_rc.lua", "/etc/rc.d/witness.lua")
  installRemote("v4/configs/witness.lua", "/etc/station/witness.lua")
  installRemote("v4/station_log_collector.lua", "/usr/lib/station_log_collector.lua")
  installRemote("v4/station_log_collector_rc.lua", "/etc/rc.d/station_log_collector.lua")
  print("")
  print("Operations profile: WITNESS + MANAGEMENT + CENTRAL LOG ARCHIVE")
  print("Run the cryptography test before commissioning:")
  print("  lua /usr/bin/admin_crypto_test.lua")
  print("Start after both core servers are installed:")
  print("  rc remote_admin start")
  print("  rc remote_admin enable")
  print("  rc station_log_collector start")
  print("  rc station_log_collector enable")
  print("  rc witness start")
  print("  rc witness enable")
  print("Management console:")
  print("  lua /usr/bin/station_admin.lua")
end

local function main()
  print("============================================================")
  print(" GALACTIC STATION V4 | THREE-SERVER INSTALLER")
  print("============================================================")
  print("This installer replaces the 17-node / 8-pair design.")
  print("Target fleet: GS-CORE-01, GS-CORE-02, STATION-WITNESS.")
  print("OpenOS must already be installed on a writable hard drive.")
  print("No drives are formatted and unrelated files are not deleted.")
  print("")

  local readOnly = false
  local ok, value = pcall(filesystem.isReadOnly, "/")
  if ok then readOnly = value == true end
  if readOnly then
    print("ERROR: root filesystem is read-only.")
    print("Boot the OpenOS floppy, run 'install', install to a hard drive, then retry.")
    return
  end

  if not component.isAvailable or not component.isAvailable("internet") then
    error("An Internet Card is required for initial GitHub bootstrap.")
  end

  print("Choose this server's role:")
  print("1 = PRIMARY core (GS-CORE-01)")
  print("2 = STANDBY core (GS-CORE-02)")
  print("3 = OPERATIONS (witness + admin console + log archive)")
  local choice = ask("Selection")
  local networkId = ask("Station network ID", DEFAULT_NETWORK)

  if choice == "1" then
    installCore(true, networkId)
  elseif choice == "2" then
    installCore(false, networkId)
  elseif choice == "3" then
    installOperations(networkId)
  else
    error("Invalid selection.")
  end

  print("")
  print("============================================================")
  print(" V4 INSTALLATION FILES PREPARED")
  print("============================================================")
  print("Install all three server profiles before starting any station services.")
  print("Then follow V4_INSTALL.md for rack networking and commissioning.")
end

local ok, err = pcall(main)
if not ok then
  print("")
  print("INSTALLATION FAILED: " .. tostring(err))
  print("Existing files were preserved or backed up where possible.")
end
