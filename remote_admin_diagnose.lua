-- Galactic Station remote administration diagnostic.
-- Safe diagnostic only: it never reveals the management secret and does not
-- send, modify, delete, or control anything.
--
-- Run on the management computer and one test node:
--   lua /tmp/remote_admin_diagnose.lua

local component = require("component")
local filesystem = require("filesystem")
local computer = require("computer")
local cryptoOK, crypto = pcall(require, "admin_crypto")

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function config(path)
  local ok, value = pcall(dofile, path)
  if ok and type(value) == "table" then return value end
  return nil
end

local cfg = config("/etc/station/admin.lua")
local kind, nodeId, networkId = "management", "ADMIN", nil
if cfg then networkId = cfg.network_id end

if not networkId then
  cfg = config("/etc/station/node.lua")
  if cfg and cfg.node_id then
    kind, nodeId, networkId = "core", cfg.node_id, cfg.network_id
  end
end
if not networkId then
  cfg = config("/etc/station/witness.lua")
  if cfg and cfg.network_id then
    kind, nodeId, networkId = "witness", "STATION-WITNESS", cfg.network_id
  end
end
if not networkId then
  cfg = config("/etc/station/module.lua")
  if cfg and cfg.module_id then
    kind, nodeId, networkId = "module", cfg.module_id, cfg.network_id
  end
end

local key = read("/etc/station/remote_admin.key")
if key then key = key:gsub("[\r\n]+$", "") end
local fingerprint = "MISSING"
if key and cryptoOK then
  fingerprint = crypto.hex(crypto.sha256(key)):sub(1, 16)
elseif key then
  fingerprint = "CRYPTO MODULE UNAVAILABLE"
end

print("============================================================")
print(" GALACTIC STATION | REMOTE ADMIN DIAGNOSTIC")
print("============================================================")
print("Computer address: " .. tostring(computer.address()))
print("Role: " .. tostring(kind))
print("Node ID: " .. tostring(nodeId))
print("Network ID: " .. tostring(networkId or "MISSING"))
print("Key present: " .. tostring(key ~= nil))
print("Key length: " .. tostring(key and #key or 0) .. " characters")
print("Key fingerprint: " .. fingerprint)
print("Crypto module: " .. tostring(cryptoOK))
if cryptoOK then
  local ok = crypto.selfTest()
  print("Crypto self-test: " .. (ok and "PASS" or "FAIL"))
else
  print("Crypto load error: " .. tostring(crypto))
end

print("")
print("REQUIRED FILES")
local paths = {
  "/usr/lib/admin_crypto.lua",
  "/usr/lib/remote_admin_agent.lua",
  "/etc/rc.d/remote_admin.lua",
  "/etc/station/remote_admin.key",
  "/etc/station/node.lua",
  "/etc/station/witness.lua",
  "/etc/station/module.lua",
  "/var/station/remote_admin_status.txt"
}
for _, path in ipairs(paths) do
  print(string.format("%-48s %s", path, filesystem.exists(path) and "PRESENT" or "absent"))
end

print("")
print("MODEMS")
local count = 0
for address in component.list("modem", true) do
  count = count + 1
  local modem = component.proxy(address)
  local openOK, openResult = pcall(modem.open, 45822)
  local isOpenOK, isOpen = pcall(modem.isOpen, 45822)
  local wirelessOK, wireless = pcall(modem.isWireless)
  local strengthOK, strength = pcall(modem.getStrength)
  print("Address: " .. tostring(address))
  print("  open(45822): " .. tostring(openOK and openResult))
  print("  isOpen(45822): " .. tostring(isOpenOK and isOpen))
  print("  wireless: " .. tostring(wirelessOK and wireless))
  print("  strength: " .. tostring(strengthOK and strength or "n/a"))
end
if count == 0 then print("NO MODEM COMPONENT FOUND") end

print("")
print("AGENT STATUS")
local status = read("/var/station/remote_admin_status.txt")
if status then
  io.write(status)
else
  print("No agent status file yet.")
  print("The diagnostic-aware agent has not started, or the installed agent is an older build.")
end

print("")
print("This diagnostic does not print or transmit the management secret.")
print("============================================================")
