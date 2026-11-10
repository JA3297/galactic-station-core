-- Galactic Station Core Runtime
-- Target: OpenComputers + OpenOS, Lua 5.2
-- Install as /usr/bin/station.lua. Configure each computer at /etc/station/node.lua.

local component = require("component")
local computer = require("computer")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")

local CONFIG_PATH = "/etc/station/node.lua"
local PORT = 45821
local MAGIC = "GALACTIC_STATION"
local PROTOCOL = 1
local HEARTBEAT_INTERVAL = 3
local LEASE_REQUEST_INTERVAL = 2
local REPLICATION_INTERVAL = 12
local STATUS_INTERVAL = 15
local LEASE_SAFETY_MARGIN = 1.0
local MAX_TELEMETRY = 300
local MAX_NODES = 128

local function fatal(message)
  io.stderr:write("STATION FATAL: " .. tostring(message) .. "\n")
  os.exit(1)
end

local okConfig, CFG = pcall(dofile, CONFIG_PATH)
if not okConfig or type(CFG) ~= "table" then
  fatal("Cannot load " .. CONFIG_PATH .. ": " .. tostring(CFG))
end

local required = {"node_id", "pair_id", "side", "role", "network_id"}
for _, key in ipairs(required) do
  if type(CFG[key]) ~= "string" or CFG[key] == "" then
    fatal("Missing required configuration value: " .. key)
  end
end
if CFG.side ~= "A" and CFG.side ~= "B" then
  fatal("side must be A or B")
end
if type(CFG.services) ~= "table" then CFG.services = {} end

local function hasService(name)
  return CFG.services[name] == true
end

local function now()
  return computer.uptime()
end

local function ensureDir(path)
  if not filesystem.exists(path) then
    local ok, reason = filesystem.makeDirectory(path)
    if not ok then fatal("Cannot create " .. path .. ": " .. tostring(reason)) end
  end
end

ensureDir("/var/station")
ensureDir("/etc/station")

-- Optional structured logger. Core supervision continues if the logger/key is absent.
local stationLogger
do
  local loggerOK, loggerValue = pcall(require, "station_logger")
  if loggerOK then stationLogger = loggerValue end
end

local function readTable(path, default)
  local file = io.open(path, "r")
  if not file then return default end
  local raw = file:read("*a")
  file:close()
  local ok, result = pcall(serialization.unserialize, raw)
  if ok and type(result) == "table" then return result end
  return default
end

local function writeTable(path, value)
  local temp = path .. ".tmp"
  local file, reason = io.open(temp, "w")
  if not file then return false, reason end
  local ok, encoded = pcall(serialization.serialize, value)
  if not ok then file:close(); return false, encoded end
  file:write(encoded)
  file:close()
  local renamed, renameReason = os.rename(temp, path)
  if not renamed then
    os.remove(path)
    renamed, renameReason = os.rename(temp, path)
  end
  return renamed, renameReason
end

local state = readTable("/var/station/state.dat", {
  telemetry = {}, nodes = {}, alarms = {}, resources = {}, events = {},
  counters = {packets = 0, malformed = 0, commands = 0, alarms = 0}
})
state.telemetry = state.telemetry or {}
state.nodes = state.nodes or {}
state.alarms = state.alarms or {}
state.resources = state.resources or {}
state.events = state.events or {}
state.counters = state.counters or {packets = 0, malformed = 0, commands = 0, alarms = 0}

-- A standby rack member starts from the most recent replicated snapshot if present.
if CFG.side == "B" then
  local replica = readTable("/var/station/replica.dat", nil)
  if replica then
    for _, key in ipairs({"telemetry", "nodes", "alarms", "resources", "events", "counters"}) do
      if type(replica[key]) == "table" then state[key] = replica[key] end
    end
  end
end

local modems = {}
for address in component.list("modem", true) do
  local modem = component.proxy(address)
  local opened = pcall(modem.open, PORT)
  if opened then table.insert(modems, modem) end
end
if #modems == 0 then fatal("No modem component found. Attach a modem and reboot this program.") end

local sequence = 0
local bootId = computer.address() .. ":" .. tostring(math.floor(now() * 1000))
local lastSequence = {}
local lastSession = {}
local leaseUntil = 0
local leaseEpoch = 0
local activeHolder = nil
local lastWitnessSeen = 0
local lastHeartbeat = 0
local lastLeaseRequest = 0
local lastReplication = 0
local lastStatus = 0
local lastSave = 0
local telemetryRules = {}
local approvedTokens = {}
local trafficWindow = {count = 0, started = now()}
local localClockOffset = nil

local function loadRules()
  local ok, rules = pcall(dofile, "/etc/station/safety_rules.lua")
  if ok and type(rules) == "table" then telemetryRules = rules end
end
loadRules()

local function loadACL()
  local ok, acl = pcall(dofile, "/etc/station/acl.lua")
  if ok and type(acl) == "table" then return acl end
  return {}
end
local ACL = loadACL()

local function isActive()
  return activeHolder == CFG.node_id and now() < leaseUntil
end

local function appendLog(kind, source, details)
  local line = string.format("%.2f\t%s\t%s\t%s\n", now(), tostring(kind), tostring(source), tostring(details or ""))
  local file = io.open("/var/station/events.log", "a")
  if file then file:write(line); file:close() end
  table.insert(state.events, {at = now(), kind = kind, source = source, details = details})
  while #state.events > 100 do table.remove(state.events, 1) end

  if stationLogger and stationLogger.write then
    local lowerKind = string.lower(tostring(kind))
    local level = "INFO"
    if lowerKind:find("error", 1, true) or lowerKind:find("failed", 1, true) then
      level = "ERROR"
    elseif lowerKind:find("reject", 1, true) or lowerKind:find("expire", 1, true) or
           lowerKind:find("denied", 1, true) then
      level = "WARNING"
    elseif lowerKind == "telemetry" then
      level = "DEBUG"
    end
    pcall(stationLogger.write, level, "station." .. tostring(kind),
      tostring(source) .. " | " .. tostring(details or ""))
  end
end

local function transmit(kind, data)
  sequence = sequence + 1
  local packet = {
    magic = MAGIC, protocol = PROTOCOL, network = CFG.network_id,
    sender = CFG.node_id, sender_role = CFG.role, pair_id = CFG.pair_id,
    side = CFG.side, boot_id = bootId, sequence = sequence, sent_at = now(), kind = kind,
    data = data or {}
  }
  local ok, encoded = pcall(serialization.serialize, packet)
  if not ok then return false end
  local sent = false
  for _, modem in ipairs(modems) do
    local success, result = pcall(modem.broadcast, PORT, encoded)
    if success and result then sent = true end
  end
  return sent
end

local function saveState()
  local ok, reason = writeTable("/var/station/state.dat", state)
  if not ok then appendLog("storage_error", CFG.node_id, reason) end
  lastSave = now()
end

local function cleanTables()
  local cutoff = now() - 180
  for id, info in pairs(state.nodes) do
    if type(info) ~= "table" or (info.seen_at or 0) < cutoff then state.nodes[id] = nil end
  end
  local count = 0
  for _ in pairs(state.telemetry) do count = count + 1 end
  if count > MAX_TELEMETRY then
    local ordered = {}
    for key, value in pairs(state.telemetry) do
      table.insert(ordered, {key = key, at = value.at or 0})
    end
    table.sort(ordered, function(a, b) return a.at < b.at end)
    for i = 1, count - MAX_TELEMETRY do state.telemetry[ordered[i].key] = nil end
  end
  count = 0
  for _ in pairs(state.nodes) do count = count + 1 end
  if count > MAX_NODES then
    local ordered = {}
    for key, value in pairs(state.nodes) do table.insert(ordered, {key = key, at = value.seen_at or 0}) end
    table.sort(ordered, function(a, b) return a.at < b.at end)
    for i = 1, count - MAX_NODES do state.nodes[ordered[i].key] = nil end
  end
end

local function snapshot()
  -- Keep the failover packet small enough for ordinary OC modem packet limits.
  local events = {}
  local first = math.max(1, #state.events - 24)
  for i = first, #state.events do table.insert(events, state.events[i]) end
  local telemetry = {}
  local ordered = {}
  for key, value in pairs(state.telemetry) do table.insert(ordered, {key = key, value = value, at = value.at or 0}) end
  table.sort(ordered, function(a, b) return a.at > b.at end)
  for i = 1, math.min(40, #ordered) do telemetry[ordered[i].key] = ordered[i].value end
  return {
    telemetry = telemetry, nodes = state.nodes, alarms = state.alarms,
    resources = state.resources, events = events, counters = state.counters
  }
end

local function processTelemetry(packet)
  if not hasService("telemetry") and not hasService("safety") and not hasService("resources") then return end
  local d = packet.data
  if type(d.module_id) ~= "string" or type(d.field) ~= "string" then return end
  local key = d.module_id .. "." .. d.field
  state.telemetry[key] = {
    module_id = d.module_id, field = d.field, value = d.value,
    unit = d.unit, at = now(), source = packet.sender
  }

  if hasService("resources") and type(d.resource) == "string" and type(d.value) == "number" then
    state.resources[d.resource] = {value = d.value, unit = d.unit, at = now(), source = d.module_id}
  end

  if hasService("safety") and type(d.value) == "number" then
    for _, rule in ipairs(telemetryRules) do
      if type(rule) == "table" and rule.field == d.field then
        local outside = (type(rule.min) == "number" and d.value < rule.min) or
                        (type(rule.max) == "number" and d.value > rule.max)
        local alarmKey = (rule.id or rule.field) .. "@" .. d.module_id
        if outside then
          if not state.alarms[alarmKey] then
            state.alarms[alarmKey] = {severity = rule.severity or "WARNING", label = rule.label or rule.field,
                                     value = d.value, unit = d.unit, at = now(), module_id = d.module_id}
            state.counters.alarms = (state.counters.alarms or 0) + 1
            appendLog("alarm_raised", d.module_id, alarmKey .. "=" .. tostring(d.value))
            if isActive() then
              transmit("station_alarm", {alarm_id = alarmKey, severity = rule.severity or "WARNING",
                       label = rule.label or rule.field, module_id = d.module_id,
                       field = d.field, value = d.value, unit = d.unit})
            end
          end
        elseif state.alarms[alarmKey] then
          state.alarms[alarmKey] = nil
          appendLog("alarm_cleared", d.module_id, alarmKey)
          if isActive() then transmit("alarm_cleared", {alarm_id = alarmKey, module_id = d.module_id}) end
        end
      end
    end
  end
end

local function processCommandRequest(packet)
  if not hasService("command") or not isActive() then return end
  local d = packet.data
  if type(d.approval_id) ~= "string" or type(d.request_id) ~= "string" or
     type(d.requester) ~= "string" or d.requester ~= packet.sender or
     type(d.operator) ~= "string" or type(d.target) ~= "string" or
     type(d.action) ~= "string" then return end
  local grant = approvedTokens[d.approval_id]
  if not grant or grant.expires < now() or grant.requester ~= d.requester or grant.operator ~= d.operator then
    transmit("command_rejected", {request_id = d.request_id, requester = d.requester, reason = "missing_or_expired_approval"})
    appendLog("command_rejected", packet.sender, d.request_id)
    return
  end
  approvedTokens[d.approval_id] = nil -- single-use approval
  state.counters.commands = (state.counters.commands or 0) + 1
  appendLog("command_dispatched", packet.sender, d.request_id .. " -> " .. d.target .. ":" .. d.action)
  transmit("command_dispatch", {
    request_id = d.request_id, requester = d.requester, operator = d.operator,
    target = d.target, action = d.action, args = d.args or {},
    approval_id = d.approval_id, issued_by = CFG.node_id
  })
end

local function processAccessRequest(packet)
  if not hasService("security") or not isActive() then return end
  local d = packet.data
  if type(d.request_id) ~= "string" or type(d.requester) ~= "string" or
     d.requester ~= packet.sender or type(d.operator) ~= "string" or
     type(d.permission) ~= "string" then return end
  local permissions = ACL[d.operator]
  local allowed = type(permissions) == "table" and
                  (permissions[d.permission] == true or permissions["*"] == true)
  local approvalId = nil
  if allowed then
    approvalId = d.request_id .. "-" .. tostring(math.floor(now() * 100)) .. "-" .. packet.sender
  end
  transmit("access_response", {
    request_id = d.request_id, requester = d.requester, operator = d.operator,
    permission = d.permission, approved = allowed == true, approval_id = approvalId,
    lifetime = allowed and 8 or 0
  })
  appendLog(allowed and "access_approved" or "access_denied", packet.sender,
            d.operator .. ":" .. d.permission)
end

local function processPacket(packet, remoteAddress)
  if type(packet) ~= "table" or packet.magic ~= MAGIC or packet.protocol ~= PROTOCOL or
     packet.network ~= CFG.network_id or type(packet.sender) ~= "string" or
     packet.sender == CFG.node_id or type(packet.kind) ~= "string" or type(packet.data) ~= "table" then
    state.counters.malformed = (state.counters.malformed or 0) + 1
    return
  end
  if type(packet.sequence) == "number" then
    local session = tostring(packet.boot_id or "unknown")
    if lastSession[packet.sender] ~= session then
      lastSession[packet.sender] = session
      lastSequence[packet.sender] = 0
    end
    if packet.sequence <= (lastSequence[packet.sender] or 0) then return end
    lastSequence[packet.sender] = packet.sequence
  end
  state.counters.packets = (state.counters.packets or 0) + 1
  trafficWindow.count = trafficWindow.count + 1

  if packet.kind == "lease_grant" then
    local d = packet.data
    if packet.sender == "STATION-WITNESS" and d.pair_id == CFG.pair_id and
       type(d.epoch) == "number" and type(d.ttl) == "number" and type(d.holder_node) == "string" then
      lastWitnessSeen = now()
      if d.epoch >= leaseEpoch then
        leaseEpoch = d.epoch
        activeHolder = d.holder_node
        if activeHolder == CFG.node_id then
          leaseUntil = now() + math.max(0, d.ttl - LEASE_SAFETY_MARGIN)
        else
          leaseUntil = 0
        end
      end
    end
    return
  end

  if packet.kind == "node_heartbeat" then
    local d = packet.data
    state.nodes[packet.sender] = {
      role = packet.sender_role, pair_id = packet.pair_id, side = packet.side,
      active = d.active == true, state = d.state or "UNKNOWN", services = d.services or {},
      seen_at = now(), uptime = d.uptime, free_memory = d.free_memory,
      total_memory = d.total_memory
    }
  elseif packet.kind == "telemetry" then
    processTelemetry(packet)
    if hasService("events") then
      appendLog("telemetry", packet.sender,
        tostring(packet.data.module_id or packet.sender) .. "." .. tostring(packet.data.field or "unknown_field"))
    end
  elseif packet.kind == "station_event" then
    if hasService("events") then appendLog(packet.data.event or "module_event", packet.sender, packet.data.detail or "") end
    if hasService("emergency") and isActive() and packet.data.severity == "EMERGENCY" then
      transmit("station_emergency", {origin = packet.sender, message = packet.data.detail or packet.data.event or "Emergency event", event = packet.data.event})
      appendLog("station_emergency_issued", packet.sender, packet.data.detail or "")
    end
  elseif packet.kind == "command_request" then
    processCommandRequest(packet)
  elseif packet.kind == "access_request" then
    processAccessRequest(packet)
  elseif packet.kind == "access_response" then
    local d = packet.data
    if hasService("command") and packet.sender_role == "security" and packet.pair_id == "PAIR-SEC" and
       d.approved == true and type(d.approval_id) == "string" and type(d.requester) == "string" then
      approvedTokens[d.approval_id] = {
        requester = d.requester, operator = d.operator,
        expires = now() + math.min(8, tonumber(d.lifetime) or 5)
      }
    end
  elseif packet.kind == "command_dispatch" then
    -- The core never actuates hardware. Module-local computers decide whether a command is valid.
    if hasService("display") then appendLog("command_visible", packet.sender, packet.data.request_id or "") end
  elseif packet.kind == "station_alarm" or packet.kind == "alarm_cleared" then
    if hasService("display") or hasService("maintenance") then
      appendLog(packet.kind, packet.sender, packet.data.alarm_id or "unknown_alarm")
    end
  elseif packet.kind == "status_request" then
    if hasService("display") and isActive() then
      transmit("status_response", {
        requester = packet.sender, node_id = CFG.node_id,
        active_nodes = (function() local n=0; for _,v in pairs(state.nodes) do if v.active then n=n+1 end end; return n end)(),
        known_nodes = (function() local n=0; for _ in pairs(state.nodes) do n=n+1 end; return n end)(),
        alarms = (function() local n=0; for _ in pairs(state.alarms) do n=n+1 end; return n end)(),
        telemetry_points = (function() local n=0; for _ in pairs(state.telemetry) do n=n+1 end; return n end)()
      })
    end
  elseif packet.kind == "time_beacon" then
    if type(packet.data.clock) == "number" then
      localClockOffset = packet.data.clock - now()
      state.station_time = {source = packet.sender, offset = localClockOffset, received_at = now(), epoch = packet.data.epoch}
    end
  elseif packet.kind == "replica_snapshot" then
    if packet.pair_id == CFG.pair_id and packet.side ~= CFG.side and hasService("backup") and
       type(packet.data.snapshot) == "table" then
      local ok = writeTable("/var/station/replica.dat", packet.data.snapshot)
      if not ok then appendLog("replica_write_error", packet.sender, "replica.dat") end
    end
  elseif packet.kind == "station_emergency" then
    if hasService("emergency") or hasService("alarms") then
      appendLog("station_emergency_received", packet.sender, packet.data.message or "unspecified")
    end
  end
end

local function printStatus()
  local activeCount, knownCount, alarmCount, telemetryCount = 0, 0, 0, 0
  for _, info in pairs(state.nodes) do knownCount = knownCount + 1; if info.active then activeCount = activeCount + 1 end end
  for _ in pairs(state.alarms) do alarmCount = alarmCount + 1 end
  for _ in pairs(state.telemetry) do telemetryCount = telemetryCount + 1 end
  local status = isActive() and "ACTIVE" or "STANDBY / NO LEASE"
  if now() - lastWitnessSeen > 12 then status = status .. " / WITNESS NOT HEARD" end
  print("\n[STATION CORE] " .. CFG.node_id .. " | " .. status)
  print("Role: " .. CFG.role .. " | Pair: " .. CFG.pair_id .. " | Side: " .. CFG.side .. " | Epoch: " .. tostring(leaseEpoch))
  print("Services: " .. table.concat((function() local t={}; for k,v in pairs(CFG.services) do if v then table.insert(t,k) end end; table.sort(t); return t end)(), ", "))
  print("Network: " .. tostring(#modems) .. " modem(s) | Nodes: " .. tostring(activeCount) .. "/" .. tostring(knownCount) .. " active/known")
  print("Telemetry: " .. tostring(telemetryCount) .. " | Active alarms: " .. tostring(alarmCount) .. " | Packets: " .. tostring(state.counters.packets or 0))
  print("Lease remaining: " .. string.format("%.1fs", math.max(0, leaseUntil - now())))
end

local function sendHeartbeat()
  local services = {}
  for key, value in pairs(CFG.services) do if value then table.insert(services, key) end end
  table.sort(services)
  transmit("node_heartbeat", {
    active = isActive(), state = isActive() and "ACTIVE" or "STANDBY",
    services = services, uptime = now(), free_memory = computer.freeMemory(),
    total_memory = computer.totalMemory()
  })
end

local function sendLeaseRequest()
  transmit("lease_request", {pair_id = CFG.pair_id, side = CFG.side, node_id = CFG.node_id})
end

local function sendReplication()
  if hasService("backup") and isActive() then
    transmit("replica_snapshot", {snapshot = snapshot()})
  end
end

local function sendTimeBeacon()
  if hasService("time") and isActive() then
    transmit("time_beacon", {clock = now(), epoch = leaseEpoch})
  end
end

local function statusLine()
  if hasService("network_monitor") then
    state.network = state.network or {}
    state.network.last_window_packets = trafficWindow.count
    state.network.window_seconds = math.max(0.1, now() - trafficWindow.started)
    trafficWindow = {count = 0, started = now()}
  end
  if hasService("health") then
    local missed = {}
    for _, configured in ipairs(CFG.expected_nodes or {}) do
      if configured ~= CFG.node_id then
        local info = state.nodes[configured]
        if not info or now() - (info.seen_at or 0) > 10 then table.insert(missed, configured) end
      end
    end
    state.health = {missing_nodes = missed, checked_at = now()}
  end
end

print("Starting Galactic Station Core Runtime...")
print("Node: " .. CFG.node_id .. " | Pair: " .. CFG.pair_id .. " | Role: " .. CFG.role)
print("Waiting for STATION-WITNESS lease. No active authority is assumed at boot.")

local running = true
while running do
  local ev = {event.pull(0.25)}
  if ev[1] == "interrupted" then
    running = false
  elseif ev[1] == "modem_message" then
    local localAddress, remoteAddress, port, distance, payload = ev[2], ev[3], ev[4], ev[5], ev[6]
    if port == PORT and type(payload) == "string" then
      local ok, packet = pcall(serialization.unserialize, payload)
      if ok then processPacket(packet, remoteAddress) else state.counters.malformed = (state.counters.malformed or 0) + 1 end
    end
  end

  local t = now()
  if t - lastLeaseRequest >= LEASE_REQUEST_INTERVAL then sendLeaseRequest(); lastLeaseRequest = t end
  if t - lastHeartbeat >= HEARTBEAT_INTERVAL then sendHeartbeat(); lastHeartbeat = t end
  if t - lastReplication >= REPLICATION_INTERVAL then sendReplication(); lastReplication = t end
  if t - lastStatus >= STATUS_INTERVAL then
    statusLine()
    if hasService("display") or hasService("command") or hasService("safety") then printStatus() end
    if hasService("time") and isActive() then sendTimeBeacon() end
    lastStatus = t
  end
  if t - lastSave >= 30 then cleanTables(); saveState() end
  for token, grant in pairs(approvedTokens) do if grant.expires < t then approvedTokens[token] = nil end end
  if leaseUntil > 0 and t >= leaseUntil then
    activeHolder = nil
    leaseUntil = 0
    appendLog("lease_lost", CFG.node_id, "Witness renewal not received; relinquishing active role")
    print("WARNING: lease expired. This computer is now STANDBY.")
  end
end

saveState()
print("Station core runtime stopped. Local module systems are unaffected.")
