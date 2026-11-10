-- Galactic Station structured local + central logger.
-- Install as /usr/lib/station_logger.lua.
-- Sends authenticated log records to the archive pair on port 45823.
-- Maintains a local rotating spool even if the archive pair is unavailable.
-- HMAC authenticates log packets; they are not encrypted.

local M = {}
local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")
local serialization = require("serialization")

local PORT = 45823
local KEY_PATH = "/etc/station/remote_admin.key"
local SPOOL_DIR = "/var/station/log-spool"
local SPOOL_FILE = SPOOL_DIR .. "/active.log"
local MAX_SPOOL = 262144
local NETWORK_ID = "GALACTIC-STATION-01"

local cryptoOK, crypto = pcall(require, "admin_crypto")
local keyFile = io.open(KEY_PATH, "rb")
local key = keyFile and keyFile:read("*a") or nil
if keyFile then keyFile:close() end
if key then key = key:gsub("[\r\n]+$", "") end

local cfg
local function loadConfig(path)
  local ok, value = pcall(dofile, path)
  if ok and type(value) == "table" then return value end
end
cfg = loadConfig("/etc/station/node.lua") or
      loadConfig("/etc/station/module.lua") or
      loadConfig("/etc/station/witness.lua") or {}
NETWORK_ID = cfg.network_id or NETWORK_ID
local SENDER = cfg.node_id or cfg.module_id or "STATION-WITNESS"
local BOOT_ID = computer.address():sub(1, 18) .. "-" .. tostring(math.floor(computer.uptime() * 1000))
local sequence = 0
local modems = {}

filesystem.makeDirectory(SPOOL_DIR)
for address in component.list("modem", true) do
  local modem = component.proxy(address)
  pcall(modem.open, PORT)
  modems[#modems + 1] = modem
end

local function clean(value, maxLength)
  value = tostring(value or "")
  value = value:gsub("[\r\n\0]", " ")
  if #value > maxLength then value = value:sub(1, maxLength) end
  return value
end

local function rotate(path, maxBytes)
  if filesystem.exists(path) and filesystem.size(path) >= maxBytes then
    os.remove(path .. ".2")
    if filesystem.exists(path .. ".1") then os.rename(path .. ".1", path .. ".2") end
    os.rename(path, path .. ".1")
  end
end

local function appendLocal(record)
  rotate(SPOOL_FILE, MAX_SPOOL)
  local f = io.open(SPOOL_FILE, "a")
  if not f then return false end
  f:write(serialization.serialize(record), "\n")
  f:close()
  return true
end

local function broadcast(record)
  if not cryptoOK or not key or #key < 32 then return false end
  if #modems == 0 then return false end
  local body = serialization.serialize({
    protocol = 1, network = NETWORK_ID, kind = "log_record", record = record
  })
  local packet = serialization.serialize({body = body, mac = crypto.hmac(key, body)})
  if #packet > 6000 then return false end
  local sent = false
  for _, modem in ipairs(modems) do
    local ok, result = pcall(modem.broadcast, PORT, packet)
    if ok and result then sent = true end
  end
  return sent
end

function M.write(level, source, message, fields)
  sequence = sequence + 1
  local record = {
    id = SENDER .. "/" .. BOOT_ID .. "/" .. tostring(sequence),
    sender = SENDER, boot_id = BOOT_ID, sequence = sequence,
    uptime = computer.uptime(),
    level = clean(level or "INFO", 12),
    source = clean(source or "unknown", 48),
    message = clean(message or "", 1200)
  }
  if type(fields) == "table" then
    record.fields = {}
    local count = 0
    for k, v in pairs(fields) do
      count = count + 1
      if count > 12 then break end
      local t = type(v)
      if t == "string" or t == "number" or t == "boolean" then
        record.fields[clean(k, 40)] = t == "string" and clean(v, 160) or v
      end
    end
  end
  local localOK = appendLocal(record)
  local networkOK = broadcast(record)
  return localOK, networkOK
end

function M.status()
  return {
    sender = SENDER, network = NETWORK_ID, port = PORT,
    key_loaded = cryptoOK and key ~= nil and #key >= 32,
    modem_count = #modems, sequence = sequence,
    spool = SPOOL_FILE, spool_size = filesystem.size(SPOOL_FILE)
  }
end

return M
