-- Galactic Station archive log collector.
-- Install on both CORE-A4 and CORE-B4 only.
-- Driver mode: receives authenticated log records on port 45823 via event.listen.
-- Both archive nodes keep independent rotating copies of the same log stream.
-- This is mirrored archive storage, not hardware RAID.

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local serialization = require("serialization")
local crypto = require("admin_crypto")

local PORT = 45823
local PROTOCOL = 1
local KEY_PATH = "/etc/station/remote_admin.key"
local LOG_DIR = "/var/station/logs"
local LOG_FILE = LOG_DIR .. "/station.log"
local SEEN_FILE = LOG_DIR .. "/seen.dat"
local MAX_LOG_BYTES = 524288
local BACKUP_COUNT = 4

local cfg = dofile("/etc/station/node.lua")
if type(cfg) ~= "table" or cfg.role ~= "archive" or cfg.pair_id ~= "PAIR-DATA" then
  print("[LOG COLLECTOR] Refusing to run: this computer is not the archive pair.")
  return
end

local function readAll(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local value = f:read("*a"); f:close(); return value
end

local key = readAll(KEY_PATH)
if not key then print("[LOG COLLECTOR] Missing remote admin key."); return end
key = key:gsub("[\r\n]+$", "")
if #key < 32 then print("[LOG COLLECTOR] Key is too short."); return end
if not crypto.selfTest() then print("[LOG COLLECTOR] Crypto self-test failed."); return end

filesystem.makeDirectory(LOG_DIR)
local seen = {}
local seenOrder = {}
local rawSeen = readAll(SEEN_FILE)
if rawSeen then
  local ok, data = pcall(serialization.unserialize, rawSeen)
  if ok and type(data) == "table" then
    for _, id in ipairs(data) do
      if type(id) == "string" then seen[id] = true; seenOrder[#seenOrder + 1] = id end
    end
  end
end

local modems = {}
for address in component.list("modem", true) do
  local modem = component.proxy(address)
  pcall(modem.open, PORT)
  modems[#modems + 1] = modem
end
if #modems == 0 then print("[LOG COLLECTOR] No modem found."); return end

local accepted, rejected = 0, 0

local function saveSeen()
  local f = io.open(SEEN_FILE .. ".tmp", "w")
  if not f then return end
  f:write(serialization.serialize(seenOrder))
  f:close()
  os.remove(SEEN_FILE)
  os.rename(SEEN_FILE .. ".tmp", SEEN_FILE)
end

local function rotateLogs()
  if not filesystem.exists(LOG_FILE) or filesystem.size(LOG_FILE) < MAX_LOG_BYTES then return end
  os.remove(LOG_FILE .. "." .. tostring(BACKUP_COUNT))
  for i = BACKUP_COUNT - 1, 1, -1 do
    if filesystem.exists(LOG_FILE .. "." .. tostring(i)) then
      os.rename(LOG_FILE .. "." .. tostring(i), LOG_FILE .. "." .. tostring(i + 1))
    end
  end
  os.rename(LOG_FILE, LOG_FILE .. ".1")
end

local function safeField(value)
  return tostring(value or ""):gsub("[\r\n\0]", " "):sub(1, 1200)
end

local function appendRecord(record)
  local id = tostring(record.id or "")
  if id == "" or seen[id] then return end

  rotateLogs()
  local message = safeField(record.message)
  local line = string.format(
    "%10.1f %-8s %-22s %-22s %s",
    tonumber(record.uptime) or 0,
    safeField(record.level):upper(),
    safeField(record.sender):sub(1,22),
    safeField(record.source):sub(1,22),
    message
  )
  if type(record.fields) == "table" then
    local ok, fields = pcall(serialization.serialize, record.fields)
    if ok then line = line .. " | " .. tostring(fields):sub(1,500) end
  end
  local f = io.open(LOG_FILE, "a")
  if not f then rejected = rejected + 1; return end
  f:write(line, "\n")
  f:close()

  seen[id] = true
  seenOrder[#seenOrder + 1] = id
  if #seenOrder > 3000 then
    local removed = table.remove(seenOrder, 1)
    seen[removed] = nil
  end
  accepted = accepted + 1
  if accepted % 25 == 0 then saveSeen() end
end

local function onMessage(_, localAddress, remoteAddress, port, distance, payload)
  if port ~= PORT or type(payload) ~= "string" or #payload > 6000 then return end
  local ok, envelope = pcall(serialization.unserialize, payload)
  if not ok or type(envelope) ~= "table" or type(envelope.body) ~= "string" or type(envelope.mac) ~= "string" then
    rejected = rejected + 1
    return
  end
  if not crypto.equal(crypto.hmac(key, envelope.body), envelope.mac) then
    rejected = rejected + 1
    return
  end
  local bodyOK, body = pcall(serialization.unserialize, envelope.body)
  if not bodyOK or type(body) ~= "table" or body.protocol ~= PROTOCOL or
     body.network ~= cfg.network_id or body.kind ~= "log_record" or type(body.record) ~= "table" then
    rejected = rejected + 1
    return
  end
  appendRecord(body.record)
end

local listenerId = event.listen("modem_message", onMessage)
if not listenerId then print("[LOG COLLECTOR] Could not register modem listener."); return end

print("[LOG COLLECTOR] " .. cfg.node_id .. " collecting authenticated logs on port " .. PORT)
print("[LOG COLLECTOR] File: " .. LOG_FILE)
