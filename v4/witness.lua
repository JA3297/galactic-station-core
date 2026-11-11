-- Galactic Station Cluster Witness
-- Target: OpenComputers + OpenOS, Lua 5.2
-- Run on a dedicated computer outside the service module if practical.
-- The witness grants short, renewable leases to one member of each server pair.

local component = require("component")
local computer = require("computer")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")

local CFG = dofile("/etc/station/witness.lua")
local PORT = 45821
local MAGIC = "GALACTIC_STATION"
local PROTOCOL = 1
local BOOT_GUARD = CFG.boot_guard or 10
local WITNESS_LEASE = CFG.witness_lease or 8
local GRANT_TTL = CFG.grant_ttl or 5
local REQUEST_FRESHNESS = CFG.request_freshness or 6
local LOOP_INTERVAL = 0.25

if type(CFG.network_id) ~= "string" or type(CFG.pairs) ~= "table" then
  error("Invalid /etc/station/witness.lua")
end

filesystem.makeDirectory("/var/station")
local function readState()
  local f = io.open("/var/station/witness_epoch.dat", "r")
  if not f then return {} end
  local raw = f:read("*a"); f:close()
  local ok, value = pcall(serialization.unserialize, raw)
  if ok and type(value) == "table" then return value end
  return {}
end
local epochState = readState()
local function saveState()
  local f = io.open("/var/station/witness_epoch.tmp", "w")
  if not f then return end
  f:write(serialization.serialize(epochState)); f:close()
  os.remove("/var/station/witness_epoch.dat")
  os.rename("/var/station/witness_epoch.tmp", "/var/station/witness_epoch.dat")
end

local modems = {}
for address in component.list("modem", true) do
  local modem = component.proxy(address)
  pcall(modem.open, PORT)
  table.insert(modems, modem)
end
if #modems == 0 then error("No modem attached to cluster witness") end

local pairsState = {}
for pairId, pairConfig in pairs(CFG.pairs) do
  pairsState[pairId] = {
    config = pairConfig, owner = nil, until_time = 0, last_seen = {A = -1000, B = -1000},
    epoch = tonumber(epochState[pairId]) or 0, first_request = nil
  }
end

local seq = 0
local bootId = computer.address() .. ":" .. tostring(math.floor(computer.uptime() * 1000))
local lastSequence, lastSession = {}, {}
local stationLogger
do
  local loggerOK, loggerValue = pcall(require, "station_logger")
  if loggerOK then stationLogger = loggerValue end
end
local function send(kind, data)
  seq = seq + 1
  local packet = {magic = MAGIC, protocol = PROTOCOL, network = CFG.network_id,
    sender = "STATION-WITNESS", sender_role = "witness", boot_id = bootId, sequence = seq,
    sent_at = computer.uptime(), kind = kind, data = data or {}}
  local payload = serialization.serialize(packet)
  for _, modem in ipairs(modems) do pcall(modem.broadcast, PORT, payload) end
end

local function grant(pairId, p, side, currentTime)
  local nodeId = p.config[side]
  if not nodeId then return end
  p.epoch = p.epoch + 1
  epochState[pairId] = p.epoch
  saveState()
  p.owner = side
  p.until_time = currentTime + WITNESS_LEASE
  send("lease_grant", {pair_id = pairId, holder_node = nodeId, holder_side = side,
    epoch = p.epoch, ttl = GRANT_TTL})
  print(string.format("LEASE GRANTED: %s -> %s (%s), epoch %d", pairId, nodeId, side, p.epoch))
  if stationLogger and stationLogger.write then
    pcall(stationLogger.write, "INFO", "witness.lease_granted",
      pairId .. " -> " .. nodeId .. " (" .. side .. "), epoch " .. tostring(p.epoch))
  end
end

local function announceCurrent(pairId, p, currentTime)
  if not p.owner then return end
  local remaining = math.max(0, p.until_time - currentTime)
  send("lease_grant", {pair_id = pairId, holder_node = p.config[p.owner],
    holder_side = p.owner, epoch = p.epoch, ttl = math.min(GRANT_TTL, remaining)})
end

local started = computer.uptime()
local lastHeartbeat = 0
print("STATION-WITNESS online. Boot safety guard: " .. tostring(BOOT_GUARD) .. " seconds.")
print("No server pair can become active until the boot guard expires.")

while true do
  local ev = {event.pull(LOOP_INTERVAL)}
  local t = computer.uptime()
  if ev[1] == "modem_message" then
    local port, payload = ev[4], ev[6]
    if port == PORT and type(payload) == "string" then
      local ok, packet = pcall(serialization.unserialize, payload)
      if ok and type(packet) == "table" and packet.magic == MAGIC and
         packet.protocol == PROTOCOL and packet.network == CFG.network_id and
         packet.kind == "lease_request" and type(packet.sender) == "string" and
         type(packet.sequence) == "number" and type(packet.data) == "table" then
        local session = tostring(packet.boot_id or "unknown")
        if lastSession[packet.sender] ~= session then
          lastSession[packet.sender] = session
          lastSequence[packet.sender] = 0
        end
        if type(packet.sequence) == "number" and packet.sequence > (lastSequence[packet.sender] or 0) then
          lastSequence[packet.sender] = packet.sequence
        else
          packet = nil
        end
        if packet then
        local d = packet.data
        local p = pairsState[d.pair_id]
        if p and (d.side == "A" or d.side == "B") and p.config[d.side] == packet.sender and d.node_id == packet.sender then
          p.last_seen[d.side] = t
          if t >= started + BOOT_GUARD then
            if p.owner and t < p.until_time then
              if p.owner == d.side then
                p.until_time = t + WITNESS_LEASE
                announceCurrent(d.pair_id, p, t)
              else
                announceCurrent(d.pair_id, p, t)
              end
            else
              -- Hold a brief election window so the preferred rack has a fair chance to announce.
              if not p.first_request then p.first_request = t end
            end
          end
        end
        end
      end
    end
  end

  -- Expire leases and elect only from candidates heard recently. The short election
  -- window gives the configured preferred side time to announce after a reboot.
  for pairId, p in pairs(pairsState) do
    if p.owner and t >= p.until_time then
      print("LEASE EXPIRED: " .. pairId .. " / " .. tostring(p.config[p.owner]))
      if stationLogger and stationLogger.write then
        pcall(stationLogger.write, "WARNING", "witness.lease_expired",
          pairId .. " / " .. tostring(p.config[p.owner]))
      end
      p.owner = nil
      p.until_time = 0
      p.first_request = t
    end
    if not p.owner and t >= started + BOOT_GUARD and p.first_request and t - p.first_request >= 1.0 then
      local aFresh = (t - p.last_seen.A) <= REQUEST_FRESHNESS
      local bFresh = (t - p.last_seen.B) <= REQUEST_FRESHNESS
      local preferred = p.config.preferred_side or "A"
      local chosen = nil
      if preferred == "B" then
        if bFresh then chosen = "B" elseif aFresh then chosen = "A" end
      else
        if aFresh then chosen = "A" elseif bFresh then chosen = "B" end
      end
      if chosen then
        p.first_request = nil
        grant(pairId, p, chosen, t)
      elseif not aFresh and not bFresh then
        p.first_request = nil
      end
    end
  end

  if t - lastHeartbeat >= 5 then
    send("witness_heartbeat", {uptime = t, pairs = (function() local n=0; for _ in pairs(pairsState) do n=n+1 end; return n end)()})
    lastHeartbeat = t
  end
end
