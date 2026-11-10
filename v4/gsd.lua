-- Galactic Station v4 daemon.
-- One resident process per server. This process owns the modem port and its
-- event.pull loop; no event.listen callbacks are registered.
--
-- Roles:
--   core         primary/standby lease client
--   hub          witness, node registry, central log archive, admin agent
--   life_support read-only machine telemetry sampler
--
-- Port: 45840. All v4 packets are AES-encrypted and HMAC-SHA256 authenticated
-- using the Tier 3 Data Card. The per-station key is local-only.

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local serialization = require("serialization")

local CONFIG_PATH = "/etc/galactic/config.lua"
local KEY_PATH = "/etc/galactic/master.key"
local PORT = 45840
local PROTOCOL = 4
local LEASE_TTL = 7
local LEASE_REQUEST_INTERVAL = 2
local HEARTBEAT_INTERVAL = 4
local LIFE_INTERVAL = 5
local LOG_LIMIT = 524288
local BOOT_GUARD = 10

local function loadTable(path)
  local ok, value = pcall(dofile, path)
  if ok and type(value) == "table" then return value end
  return nil
end

local cfg = loadTable(CONFIG_PATH)
if not cfg or not cfg.node_id or not cfg.role or not cfg.network_id then
  error("Missing or invalid " .. CONFIG_PATH .. ". Run gs_bootstrap.lua.")
end

local keyFile = io.open(KEY_PATH, "rb")
if not keyFile then error("Missing " .. KEY_PATH .. ". Re-run the v4 bootstrap.") end
local stationKey = keyFile:read("*a") or ""
keyFile:close()
stationKey = stationKey:gsub("[\r\n]+$", "")
if #stationKey ~= 64 or stationKey:find("[^%x]") then
  error("Invalid station key. Expected 64 hexadecimal characters.")
end

local crypto = require("gs_crypto")
local cryptoOK, cryptoErr = crypto.selfTest()
if not cryptoOK then error("Data Card cryptographic self-test failed: " .. tostring(cryptoErr)) end

filesystem.makeDirectory("/var/galactic")
filesystem.makeDirectory("/var/galactic/logs")
filesystem.makeDirectory("/var/galactic/state")
filesystem.makeDirectory("/var/galactic/tmp")

local modems = {}
for address in component.list("modem", true) do
  local proxy = component.proxy(address)
  pcall(proxy.open, PORT)
  modems[#modems + 1] = {address = address, proxy = proxy}
end
if #modems == 0 then error("No wired Network Card/modem component detected.") end

local startedAt = computer.uptime()
local active = false
local leaseDeadline = 0
local witnessOwner = nil
local witnessExpires = 0
local primaryLastSeen = 0
local standbyLastSeen = 0
local registry = {}
local transfers = {}
local lastSeq = {}
local seqPath = "/var/galactic/state/admin_sequences.dat"
local sequenceFile = io.open(seqPath, "rb")
if sequenceFile then
  local raw = sequenceFile:read("*a")
  sequenceFile:close()
  local ok, value = pcall(serialization.unserialize, raw or "")
  if ok and type(value) == "table" then lastSeq = value end
end

local function saveSequences()
  local temp = seqPath .. ".tmp"
  local f = io.open(temp, "wb")
  if not f then return false end
  local ok, encoded = pcall(serialization.serialize, lastSeq)
  if not ok then f:close(); os.remove(temp); return false end
  f:write(encoded)
  f:close()
  local renamed = os.rename(temp, seqPath)
  if not renamed then os.remove(temp); return false end
  return true
end

local function log(level, source, message, fields)
  local record = {
    uptime = computer.uptime(),
    node = cfg.node_id,
    level = tostring(level or "INFO"),
    source = tostring(source or "gsd"),
    message = tostring(message or ""):gsub("[\r\n\0]", " "):sub(1, 900),
    fields = type(fields) == "table" and fields or nil
  }
  local path = "/var/galactic/logs/gs.log"
  if filesystem.exists(path) and filesystem.size(path) >= LOG_LIMIT then
    os.remove(path .. ".2")
    if filesystem.exists(path .. ".1") then os.rename(path .. ".1", path .. ".2") end
    os.rename(path, path .. ".1")
  end
  local f = io.open(path, "a")
  if f then
    f:write(serialization.serialize(record), "\n")
    f:close()
  end
end

local function pack(message)
  message.protocol = PROTOCOL
  message.station = cfg.station_id
  message.network = cfg.network_id
  message.sender = cfg.node_id
  message.uptime = computer.uptime()
  return crypto.seal(stationKey, serialization.serialize(message))
end

local function send(remoteAddress, message, localAddress)
  local payload, err = pack(message)
  if not payload then log("ERROR", "network", "packet encryption failed", {error = err}); return false end
  local sent = false
  for _, item in ipairs(modems) do
    if not localAddress or item.address == localAddress then
      local ok, result
      if remoteAddress then
        ok, result = pcall(item.proxy.send, remoteAddress, PORT, payload)
      else
        ok, result = pcall(item.proxy.broadcast, PORT, payload)
      end
      if ok and result then sent = true end
    end
  end
  return sent
end

local function safeDecode(payload)
  if type(payload) ~= "string" or #payload > 7800 then return nil, "packet size/type invalid" end
  local raw, err = crypto.open(stationKey, payload)
  if not raw then return nil, err end
  local ok, message = pcall(serialization.unserialize, raw)
  if not ok or type(message) ~= "table" then return nil, "inner serialization invalid" end
  if message.protocol ~= PROTOCOL or message.station ~= cfg.station_id or
     message.network ~= cfg.network_id then return nil, "station/protocol mismatch" end
  return message
end

local function sendReply(remoteAddress, localAddress, request, ok, result, err)
  send(remoteAddress, {
    kind = "reply",
    request_id = request.request_id,
    target = request.sender,
    ok = ok == true,
    result = result,
    error = err
  }, localAddress)
end

local function nodeInfo()
  local count, types = 0, {}
  for _, typeName in component.list() do
    count = count + 1
    types[typeName] = (types[typeName] or 0) + 1
  end
  return {
    node_id = cfg.node_id,
    role = cfg.role,
    side = cfg.side,
    pair_id = cfg.pair_id,
    network_id = cfg.network_id,
    protocol = PROTOCOL,
    uptime = computer.uptime(),
    free_memory = computer.freeMemory(),
    total_memory = computer.totalMemory(),
    component_count = count,
    component_types = types,
    modem_count = #modems,
    active = active,
    lease_remaining = math.max(0, leaseDeadline - computer.uptime()),
    witness_owner = cfg.role == "hub" and witnessOwner or nil
  }
end

local function validPath(path)
  if type(path) ~= "string" or #path < 1 or #path > 220 then
    return nil, "path must contain 1-220 characters"
  end
  if path:find("%z") or path:find("\\", 1, true) then return nil, "invalid path character" end
  for segment in path:gmatch("[^/]+") do
    if segment == ".." then return nil, "parent traversal denied" end
  end
  if path:sub(1,1) ~= "/" then path = "/" .. path end
  local ok, canonical = pcall(filesystem.canonical, path)
  if ok and type(canonical) == "string" then path = canonical end
  return path
end

local function protectedPath(path)
  local p = string.lower(path)
  return p == "/etc/galactic/master.key" or p == "/etc/galactic/config.lua"
      or p == "/etc/galactic" or p:find("/master.key", 1, true) ~= nil
end

local function protectedDelete(path)
  if protectedPath(path) then return true end
  return path == "/" or path == "/boot" or path == "/bin" or
    path == "/lib" or path == "/usr" or path == "/etc" or path == "/var"
end

local function listDirectory(path, offset, limit)
  if not filesystem.exists(path) then return nil, "directory does not exist" end
  if not filesystem.isDirectory(path) then return nil, "not a directory" end
  local iter, err = filesystem.list(path)
  if not iter then return nil, tostring(err or "cannot list directory") end

  offset = math.max(0, math.floor(tonumber(offset) or 0))
  limit = math.max(1, math.min(24, math.floor(tonumber(limit) or 24)))
  local names, scanned = {}, 0
  for name in iter do
    scanned = scanned + 1
    if scanned > 400 then break end
    names[#names + 1] = tostring(name)
  end
  table.sort(names)

  local entries = {}
  for i = offset + 1, math.min(#names, offset + limit) do
    local name = names[i]
    local full = name:sub(1,1) == "/" and name or
      ((path == "/" and "/" or path .. "/") .. name)
    local isDir = filesystem.isDirectory(full)
    entries[#entries + 1] = {
      name = name,
      directory = isDir,
      size = isDir and 0 or filesystem.size(full),
      modified = filesystem.lastModified(full)
    }
  end
  return {
    path = path, total = #names, offset = offset,
    entries = entries,
    next_offset = #names > offset + limit and offset + limit or nil,
    truncated = scanned > 400
  }
end

local function safeExec(command)
  if command == "uptime" then
    return {uptime = computer.uptime()}
  elseif command == "memory" then
    return {free = computer.freeMemory(), total = computer.totalMemory()}
  elseif command == "components" then
    local items = {}
    for address, typeName in component.list() do
      items[#items + 1] = {address = address, type = typeName}
    end
    return items
  elseif command == "mounts" then
    local items = {}
    for proxy, path in filesystem.mounts() do
      local label = "unknown"
      local total, used = 0, 0
      pcall(function() if proxy.getLabel then label = proxy.getLabel() end end)
      pcall(function() if proxy.spaceTotal then total = proxy.spaceTotal() end end)
      pcall(function() if proxy.spaceUsed then used = proxy.spaceUsed() end end)
      items[#items + 1] = {path = path, label = label, total = total, used = used}
    end
    return items
  elseif command == "status" then
    return nodeInfo()
  elseif command == "services" then
    return listDirectory("/etc/rc.d", 0, 24)
  end
  return nil, "allowed commands: uptime, memory, components, mounts, status, services"
end

local function writeChunk(args, client)
  local path, pathErr = validPath(args.path)
  if not path then return nil, pathErr end
  if protectedPath(path) then return nil, "protected destination" end
  local transferId = tostring(args.transfer_id or "")
  if not transferId:match("^[%w_-]+$") or #transferId > 40 then return nil, "invalid transfer ID" end
  local offset, total = tonumber(args.offset), tonumber(args.total)
  local data = args.data
  if not offset or not total or type(data) ~= "string" then return nil, "invalid chunk" end
  offset, total = math.floor(offset), math.floor(total)
  if total < 0 or total > 2097152 or offset < 0 or #data > 1300 then return nil, "transfer limit exceeded" end
  if offset + #data > total then return nil, "chunk exceeds declared size" end

  local parent = filesystem.path(path)
  local base = filesystem.name(path)
  if not parent or parent == "" then parent = "/" end
  if not filesystem.exists(parent) or not filesystem.isDirectory(parent) then return nil, "destination directory missing" end

  local id = client .. ":" .. transferId
  local state = transfers[id]
  if not state then
    if offset ~= 0 then return nil, "first chunk must start at offset zero" end
    if filesystem.isDirectory(path) then return nil, "destination is a directory" end
    local temp = (parent == "/" and "" or parent) .. "/." .. base .. ".gs4-" .. transferId .. ".part"
    os.remove(temp)
    local f, err = io.open(temp, "wb")
    if not f then return nil, tostring(err) end
    f:close()
    state = {path = path, temp = temp, total = total, received = 0}
    transfers[id] = state
  end
  if state.path ~= path or state.total ~= total or state.received ~= offset then
    return nil, "chunk offset/session mismatch"
  end

  local f, err = io.open(state.temp, "ab")
  if not f then return nil, tostring(err) end
  f:write(data)
  f:close()
  state.received = state.received + #data

  if args.final == true then
    if state.received ~= state.total then return nil, "final chunk before complete file" end
    local backup = path .. ".gs4bak"
    if filesystem.exists(backup) then filesystem.remove(backup) end
    local hadOld = filesystem.exists(path)
    if hadOld then
      local moved, why = os.rename(path, backup)
      if not moved then return nil, "backup failed: " .. tostring(why) end
    end
    local moved, why = os.rename(state.temp, path)
    if not moved then
      if hadOld then os.rename(backup, path) end
      return nil, "commit failed: " .. tostring(why)
    end
    transfers[id] = nil
    log("INFO", "remote_file", "file committed", {path = path, bytes = state.received, client = client})
    return {path = path, bytes = state.received, committed = true, backup = hadOld and backup or nil}
  end
  return {path = path, received = state.received, total = total, committed = false}
end

local function performAdmin(request)
  local args = type(request.args) == "table" and request.args or {}
  local op = request.operation

  if op == "info" then
    return nodeInfo()

  elseif op == "list" then
    local path, err = validPath(args.path or "/")
    if not path then return nil, err end
    return listDirectory(path, args.offset, args.limit)

  elseif op == "stat" then
    local path, err = validPath(args.path)
    if not path then return nil, err end
    if not filesystem.exists(path) then return {path = path, exists = false} end
    return {path = path, exists = true, directory = filesystem.isDirectory(path),
      size = filesystem.size(path), modified = filesystem.lastModified(path)}

  elseif op == "read" then
    local path, err = validPath(args.path)
    if not path then return nil, err end
    if protectedPath(path) then return nil, "protected file" end
    if not filesystem.exists(path) or filesystem.isDirectory(path) then return nil, "file not found" end
    local offset = math.max(0, math.floor(tonumber(args.offset) or 0))
    local limit = math.max(1, math.min(1100, math.floor(tonumber(args.limit) or 1100)))
    local size = filesystem.size(path)
    local f, openErr = io.open(path, "rb")
    if not f then return nil, tostring(openErr) end
    local ok, seekErr = f:seek("set", offset)
    if not ok then f:close(); return nil, tostring(seekErr) end
    local data = f:read(limit) or ""
    f:close()
    return {path = path, offset = offset, size = size, data = data, eof = offset + #data >= size}

  elseif op == "write_chunk" then
    return writeChunk(args, request.sender)

  elseif op == "mkdir" then
    local path, err = validPath(args.path)
    if not path then return nil, err end
    if protectedPath(path) then return nil, "protected path" end
    local ok, why = filesystem.makeDirectory(path)
    if not ok and not filesystem.isDirectory(path) then return nil, tostring(why or "mkdir failed") end
    return {path = path, created = true}

  elseif op == "delete" then
    local path, err = validPath(args.path)
    if not path then return nil, err end
    if protectedDelete(path) then return nil, "protected path" end
    if not filesystem.exists(path) then return nil, "path does not exist" end
    local ok, why = filesystem.remove(path)
    if not ok then return nil, tostring(why or "delete failed") end
    return {path = path, deleted = true}

  elseif op == "rename" then
    local from, err = validPath(args.from)
    if not from then return nil, err end
    local to, toErr = validPath(args.to)
    if not to then return nil, toErr end
    if protectedPath(from) or protectedPath(to) or from == "/" or to == "/" then
      return nil, "protected rename"
    end
    if not filesystem.exists(from) then return nil, "source does not exist" end
    if filesystem.exists(to) then return nil, "destination already exists" end
    local ok, why = os.rename(from, to)
    if not ok then return nil, tostring(why or "rename failed") end
    return {from = from, to = to, renamed = true}

  elseif op == "tail" then
    local path, err = validPath(args.path)
    if not path then return nil, err end
    if protectedPath(path) or not filesystem.exists(path) or filesystem.isDirectory(path) then
      return nil, "log file unavailable"
    end
    local size = filesystem.size(path)
    local f, openErr = io.open(path, "rb")
    if not f then return nil, tostring(openErr) end
    local start = math.max(0, size - 32768)
    f:seek("set", start)
    local content = f:read("*a") or ""
    f:close()
    if start > 0 then
      local firstNewline = content:find("\n", 1, true)
      if firstNewline then content = content:sub(firstNewline + 1) end
    end
    local lines = {}
    for line in content:gmatch("[^\r\n]+") do lines[#lines + 1] = line end
    local count = math.max(1, math.min(80, math.floor(tonumber(args.lines) or 40)))
    local out = {}
    for i = math.max(1, #lines - count + 1), #lines do out[#out + 1] = lines[i] end
    local text = table.concat(out, "\n")
    if #text > 2300 then text = text:sub(#text - 2299) end
    return {path = path, lines = #out, text = text, truncated = start > 0 or #text >= 2300}

  elseif op == "exec" then
    return safeExec(tostring(args.command or ""))

  elseif op == "reboot" then
    if args.confirm ~= "REBOOT " .. cfg.node_id then return nil, "confirmation mismatch" end
    return {node_id = cfg.node_id, rebooting = true}
  end
  return nil, "unknown administrative operation"
end

local function receiveAdmin(message, remoteAddress, localAddress)
  if cfg.role == "hub" then return end
  if message.sender ~= cfg.manager_id then return end
  if type(message.request_id) ~= "string" or type(message.seq) ~= "number" then return end
  local last = tonumber(lastSeq[message.sender]) or 0
  if message.seq <= last then
    sendReply(remoteAddress, localAddress, message, false, nil, "replayed/old request")
    return
  end
  lastSeq[message.sender] = message.seq
  if not saveSequences() then
    lastSeq[message.sender] = last
    sendReply(remoteAddress, localAddress, message, false, nil, "cannot persist anti-replay state")
    return
  end

  local ok, result, err = pcall(function()
    local value, why = performAdmin(message)
    if value == nil then error(why or "operation failed") end
    return value
  end)
  if ok then
    sendReply(remoteAddress, localAddress, message, true, result, nil)
    log("INFO", "admin", "remote operation", {client = message.sender, operation = message.operation})
    if message.operation == "reboot" then
      event.timer(0.5, function() computer.shutdown(true) end, 1)
    end
  else
    sendReply(remoteAddress, localAddress, message, false, nil, tostring(result))
    log("WARNING", "admin", "remote operation failed", {client = message.sender, operation = message.operation, error = tostring(result)})
  end
end

local function processLeaseRequest(message, remoteAddress, localAddress)
  if cfg.role ~= "hub" or message.pair_id ~= "GS-CORE-PAIR" then return end
  local now = computer.uptime()
  if message.sender == "GS-CORE-01" then primaryLastSeen = now end
  if message.sender == "GS-CORE-02" then standbyLastSeen = now end

  if now - startedAt < BOOT_GUARD then
    send(remoteAddress, {kind = "lease_deny", target = message.sender, reason = "witness boot guard"}, localAddress)
    return
  end

  if witnessOwner and now >= witnessExpires then
    log("WARNING", "witness", "lease expired", {owner = witnessOwner})
    witnessOwner, witnessExpires = nil, 0
  end

  if witnessOwner == message.sender then
    witnessExpires = now + LEASE_TTL
  elseif not witnessOwner then
    local preferred
    if now - primaryLastSeen <= 3 then
      preferred = "GS-CORE-01"
    elseif now - standbyLastSeen <= 3 then
      preferred = "GS-CORE-02"
    end
    if preferred == message.sender then
      witnessOwner = message.sender
      witnessExpires = now + LEASE_TTL
      log("INFO", "witness", "lease granted", {owner = witnessOwner})
    end
  end

  if witnessOwner == message.sender then
    send(remoteAddress, {kind = "lease_grant", target = message.sender, ttl = LEASE_TTL}, localAddress)
  else
    send(remoteAddress, {kind = "lease_deny", target = message.sender,
      owner = witnessOwner, reason = "another core owns the lease"}, localAddress)
  end
end

local function processMessage(name, localAddress, remoteAddress, port, distance, payload)
  if name ~= "modem_message" or port ~= PORT then return end
  local message, err = safeDecode(payload)
  if not message then
    log("WARNING", "network", "packet rejected", {error = err})
    return
  end
  if message.target and message.target ~= "*" and message.target ~= cfg.node_id then return end

  if message.kind == "discover" then
    send(remoteAddress, {kind = "discover_reply", target = message.sender,
      request_id = message.request_id, info = nodeInfo()}, localAddress)

  elseif message.kind == "admin" then
    receiveAdmin(message, remoteAddress, localAddress)

  elseif message.kind == "lease_request" then
    processLeaseRequest(message, remoteAddress, localAddress)

  elseif message.kind == "lease_grant" and cfg.role == "core" and message.target == cfg.node_id then
    active = true
    leaseDeadline = computer.uptime() + (tonumber(message.ttl) or LEASE_TTL) - 1
    log("INFO", "core", "active lease renewed", {remaining = leaseDeadline - computer.uptime()})

  elseif message.kind == "lease_deny" and cfg.role == "core" and message.target == cfg.node_id then
    if active and computer.uptime() >= leaseDeadline then
      active = false
      log("WARNING", "core", "lease lost; demoted")
    end

  elseif message.kind == "heartbeat" and cfg.role == "hub" then
    registry[message.sender] = {
      last_seen = computer.uptime(),
      role = message.role,
      state = message.state,
      uptime = message.node_uptime,
      free_memory = message.free_memory,
      total_memory = message.total_memory
    }

  elseif message.kind == "life_snapshot" and cfg.role == "hub" then
    registry[message.sender] = registry[message.sender] or {}
    registry[message.sender].last_seen = computer.uptime()
    registry[message.sender].life_snapshot = message.snapshot
    log("INFO", "life_support", "snapshot received", {
      equipment = message.snapshot and #(message.snapshot.equipment or {}) or 0,
      alarms = message.snapshot and #(message.snapshot.alarms or {}) or 0
    })
    local archive = io.open("/var/galactic/logs/life_support_latest.dat", "wb")
    if archive then archive:write(serialization.serialize(message.snapshot)); archive:close() end

  elseif message.kind == "log_record" and cfg.role == "hub" then
    log(message.level, message.source, message.message, message.fields)

  elseif message.kind == "ping" then
    send(remoteAddress, {kind = "pong", target = message.sender,
      request_id = message.request_id, info = nodeInfo()}, localAddress)
  end
end

local function tickHub()
  local now = computer.uptime()
  for id, item in pairs(registry) do
    if item.last_seen and now - item.last_seen > 12 then
      item.state = "STALE"
    end
  end
  local status = {
    node = nodeInfo(),
    witness = {
      owner = witnessOwner,
      lease_remaining = math.max(0, witnessExpires - now),
      boot_guard_remaining = math.max(0, BOOT_GUARD - (now - startedAt))
    },
    nodes = registry
  }
  local file = io.open("/var/galactic/status.dat", "wb")
  if file then
    local ok, encoded = pcall(serialization.serialize, status)
    if ok then file:write(encoded) end
    file:close()
  end
end

local function tickCore()
  local now = computer.uptime()
  if now - (leaseDeadline - LEASE_TTL + 1) >= LEASE_REQUEST_INTERVAL then
    send(nil, {kind = "lease_request", target = cfg.witness_id,
      pair_id = cfg.pair_id, side = cfg.side})
    lastLeaseRequest = now
  end
  if active and now >= leaseDeadline then
    active = false
    log("WARNING", "core", "lease expired locally; demoted")
  end
end

local function tickLife()
  local now = computer.uptime()
  if now - lastLifeSample >= LIFE_INTERVAL then
    local ok, sampler = pcall(require, "gs_life")
    if ok then
      local sampleOK, snapshot = pcall(sampler.sample)
      if sampleOK then
        send(nil, {kind = "life_snapshot", target = cfg.manager_id, snapshot = snapshot})
        for _, alarm in ipairs(snapshot.alarms or {}) do
          log(alarm.severity, "life_support", alarm.code, alarm)
          send(nil, {kind = "log_record", target = cfg.manager_id,
            level = alarm.severity, source = "life_support",
            message = alarm.code, fields = alarm})
        end
        local file = io.open("/var/galactic/logs/life_support_latest.dat", "wb")
        if file then file:write(serialization.serialize(snapshot)); file:close() end
      else
        log("ERROR", "life_support", "sampler failed", {error = tostring(snapshot)})
      end
    else
      log("ERROR", "life_support", "sampler unavailable", {error = tostring(sampler)})
    end
    lastLifeSample = now
  end
end

local lastLeaseRequest = 0
local lastHeartbeat = 0
local lastLifeSample = 0
local lastHubTick = 0

log("INFO", "gsd", "Galactic Station v4 daemon started", {role = cfg.role, version = "4.0.0"})
print("[GS v4] " .. cfg.node_id .. " online; role=" .. cfg.role .. "; port=" .. PORT)

while true do
  local ev = {event.pull(0.25)}
  if ev[1] then
    processMessage(ev[1], ev[2], ev[3], ev[4], ev[5], ev[6])
  end

  local now = computer.uptime()
  if cfg.role == "core" then
    if now - lastLeaseRequest >= LEASE_REQUEST_INTERVAL then
      send(nil, {kind = "lease_request", target = cfg.witness_id,
        pair_id = cfg.pair_id, side = cfg.side})
      lastLeaseRequest = now
    end
    if active and now >= leaseDeadline then
      active = false
      log("WARNING", "core", "lease expired locally; demoted")
    end
  end

  if cfg.role ~= "hub" and now - lastHeartbeat >= HEARTBEAT_INTERVAL then
    send(nil, {kind = "heartbeat", target = cfg.manager_id,
      role = cfg.role, state = cfg.role == "core" and (active and "ACTIVE" or "STANDBY") or "ONLINE",
      node_uptime = computer.uptime(), free_memory = computer.freeMemory(),
      total_memory = computer.totalMemory()})
    lastHeartbeat = now
  end

  if cfg.role == "life_support" then tickLife() end

  if cfg.role == "hub" and now - lastHubTick >= 2 then
    tickHub()
    lastHubTick = now
  end
end
