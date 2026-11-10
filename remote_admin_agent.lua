-- Galactic Station authenticated remote administration agent.
-- OpenOS driver-mode service. Listens via event.listen so it coexists with
-- station.lua / witness.lua event.pull loops.
--
-- Requires:
--   /usr/lib/admin_crypto.lua
--   /etc/station/remote_admin.key  (same 32+ character secret on every host)
--
-- Port: 45822. HMAC-SHA256 authenticates commands; packets are NOT encrypted.
-- Never expose the station modem network to untrusted machines.

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local serialization = require("serialization")

local okCrypto, crypto = pcall(require, "admin_crypto")
if not okCrypto then
  print("[REMOTE ADMIN] crypto module unavailable: " .. tostring(crypto))
  return
end

local KEY_PATH = "/etc/station/remote_admin.key"
local PORT = 45822
local PROTOCOL = 1
local MAX_PACKET = 7000
local MAX_READ = 2500
local MAX_UPLOAD = 2097152
local VERSION = "1.0.0"
local REPLAY_PATH = "/var/station/remote_admin_replay.dat"

local function readAll(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local value = f:read("*a")
  f:close()
  return value
end

local key = readAll(KEY_PATH)
if not key then
  print("[REMOTE ADMIN] Missing " .. KEY_PATH .. "; agent remains disabled.")
  return
end
key = key:gsub("[\r\n]+$", "")
if #key < 32 then
  print("[REMOTE ADMIN] Key must contain at least 32 characters; agent disabled.")
  return
end

local selfTestOK = crypto.selfTest()
if not selfTestOK then
  print("[REMOTE ADMIN] SHA-256/HMAC self-test FAILED; agent disabled.")
  return
end

local function loadConfig(path)
  local ok, value = pcall(dofile, path)
  if ok and type(value) == "table" then return value end
  return nil
end

local cfg = loadConfig("/etc/station/node.lua")
local kind, nodeId, role, networkId, pairId, side = "unknown", nil, nil, nil, nil, nil
if cfg and cfg.node_id then
  kind, nodeId, role = "core", cfg.node_id, cfg.role
  networkId, pairId, side = cfg.network_id, cfg.pair_id, cfg.side
else
  cfg = loadConfig("/etc/station/witness.lua")
  if cfg and cfg.network_id then
    kind, nodeId, role, networkId = "witness", "STATION-WITNESS", "witness", cfg.network_id
  else
    cfg = loadConfig("/etc/station/module.lua")
    if cfg and cfg.module_id then
      kind, nodeId, role, networkId = "module", cfg.module_id, "module", cfg.network_id
    end
  end
end

if not nodeId or not networkId then
  print("[REMOTE ADMIN] Could not identify this computer. Check /etc/station configuration.")
  return
end

filesystem.makeDirectory("/var/station")
local replay = {}
local rawReplay = readAll(REPLAY_PATH)
if rawReplay then
  local ok, value = pcall(serialization.unserialize, rawReplay)
  if ok and type(value) == "table" then replay = value end
end

local function saveReplay()
  local temp = REPLAY_PATH .. ".tmp"
  local f = io.open(temp, "w")
  if not f then return end
  f:write(serialization.serialize(replay))
  f:close()
  os.remove(REPLAY_PATH)
  os.rename(temp, REPLAY_PATH)
end

local modems = {}
for address in component.list("modem", true) do
  local modem = component.proxy(address)
  local ok, opened = pcall(modem.open, PORT)
  if ok then modems[#modems + 1] = modem end
end
if #modems == 0 then
  print("[REMOTE ADMIN] No modem available; agent disabled.")
  return
end

local logger
do
  local ok, value = pcall(require, "station_logger")
  if ok then logger = value end
end

local function audit(level, message, detail)
  if logger and logger.write then
    pcall(logger.write, level, "remote_admin", message, {node = nodeId, detail = detail})
  end
end

local lastRequestAt = {}
local uploads = {}

local function makeEnvelope(body)
  local raw = serialization.serialize(body)
  return serialization.serialize({body = raw, mac = crypto.hmac(key, raw)})
end

local function sendReply(localAddress, remoteAddress, request, ok, result, err)
  local body = {
    protocol = PROTOCOL, network = networkId, kind = "reply",
    sender = nodeId, client_id = request.client_id,
    request_id = request.request_id, sequence = request.sequence,
    ok = ok == true, result = result, error = err
  }
  local encoded = makeEnvelope(body)
  local modem
  if localAddress then
    local good, proxy = pcall(component.proxy, localAddress)
    if good then modem = proxy end
  end
  if modem then
    pcall(modem.send, remoteAddress, PORT, encoded)
  else
    for _, candidate in ipairs(modems) do
      pcall(candidate.send, remoteAddress, PORT, encoded)
    end
  end
end

local function canonicalPath(path)
  if type(path) ~= "string" or #path == 0 or #path > 240 then
    return nil, "path must be a string of 1-240 characters"
  end
  if path:find("%z") or path:find("\\", 1, true) then
    return nil, "invalid path character"
  end
  for segment in path:gmatch("[^/]+") do
    if segment == ".." then return nil, "parent traversal is not allowed" end
  end
  if path:sub(1,1) ~= "/" then path = "/" .. path end
  local ok, normalized = pcall(filesystem.canonical, path)
  if ok and type(normalized) == "string" and normalized ~= "" then
    path = normalized
    if path:sub(1,1) ~= "/" then path = "/" .. path end
  end
  return path
end

local function protectedPath(path)
  local p = string.lower(path)
  if p == "/etc/station/remote_admin.key" or p:find("remote_admin.key", 1, true) then
    return true
  end
  if p == "/etc/station/node.lua" or p == "/etc/station/witness.lua" or
     p == "/etc/station/module.lua" or p == "/etc/station/install_role" then
    return true
  end
  return false
end

local function protectedDelete(path)
  if protectedPath(path) then return true end
  return path == "/" or path == "/etc" or path == "/usr" or path == "/bin" or
    path == "/boot" or path == "/lib" or path == "/var" or path == "/home"
end

local function safeList(path)
  if not filesystem.exists(path) then return nil, "directory does not exist" end
  if not filesystem.isDirectory(path) then return nil, "path is not a directory" end
  local iterator, err = filesystem.list(path)
  if not iterator then return nil, tostring(err or "cannot list directory") end
  local entries, count = {}, 0
  for name in iterator do
    count = count + 1
    if count > 100 then break end
    local full
    if name:sub(1,1) == "/" then full = name
    else full = (path == "/" and "/" or path .. "/") .. name end
    local isDir = filesystem.isDirectory(full)
    entries[#entries + 1] = {
      name = name, directory = isDir,
      size = isDir and 0 or filesystem.size(full),
      modified = filesystem.lastModified(full)
    }
  end
  table.sort(entries, function(a,b) return tostring(a.name) < tostring(b.name) end)
  return {path = path, entries = entries, truncated = count > 100}
end

local function getInfo()
  local modemCount, componentCount = 0, 0
  for address, typeName in component.list() do
    componentCount = componentCount + 1
    if typeName == "modem" then modemCount = modemCount + 1 end
  end
  return {
    node_id = nodeId, kind = kind, role = role, pair_id = pairId, side = side,
    network_id = networkId, agent_version = VERSION,
    uptime = computer.uptime(), free_memory = computer.freeMemory(),
    total_memory = computer.totalMemory(), component_count = componentCount,
    modem_count = modemCount, computer_address = computer.address()
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
      items[#items + 1] = {type = typeName, address = address}
    end
    table.sort(items, function(a,b) return tostring(a.type) < tostring(b.type) end)
    return items
  elseif command == "mounts" then
    local items = {}
    for proxy, path in filesystem.mounts() do
      items[#items + 1] = {
        path = path,
        label = (proxy.getLabel and proxy.getLabel()) or "unknown",
        total = (proxy.spaceTotal and proxy.spaceTotal()) or 0,
        used = (proxy.spaceUsed and proxy.spaceUsed()) or 0,
        readonly = (proxy.isReadOnly and proxy.isReadOnly()) or false
      }
    end
    return items
  elseif command == "services" then
    return safeList("/etc/rc.d")
  else
    return nil, "command not allowed; try uptime, memory, components, mounts, services"
  end
end

local function perform(operation, args, clientId)
  args = type(args) == "table" and args or {}

  if operation == "discover" or operation == "info" then
    return getInfo()

  elseif operation == "list" then
    local path, err = canonicalPath(args.path or "/")
    if not path then return nil, err end
    return safeList(path)

  elseif operation == "stat" then
    local path, err = canonicalPath(args.path)
    if not path then return nil, err end
    if not filesystem.exists(path) then return {path = path, exists = false} end
    return {
      path = path, exists = true, directory = filesystem.isDirectory(path),
      size = filesystem.size(path), modified = filesystem.lastModified(path)
    }

  elseif operation == "read" then
    local path, err = canonicalPath(args.path)
    if not path then return nil, err end
    if protectedPath(path) then return nil, "protected file" end
    if not filesystem.exists(path) or filesystem.isDirectory(path) then return nil, "file not found" end
    local offset = math.max(0, math.floor(tonumber(args.offset) or 0))
    local limit = math.max(1, math.min(MAX_READ, math.floor(tonumber(args.limit) or MAX_READ)))
    local f, openErr = io.open(path, "rb")
    if not f then return nil, tostring(openErr) end
    local size = filesystem.size(path)
    local seekOK, seekErr = f:seek("set", offset)
    if not seekOK then f:close(); return nil, tostring(seekErr or "seek failed") end
    local data = f:read(limit) or ""
    f:close()
    return {path = path, offset = offset, size = size, data = data, eof = offset + #data >= size}

  elseif operation == "tail" then
    local path, err = canonicalPath(args.path)
    if not path then return nil, err end
    if protectedPath(path) then return nil, "protected file" end
    if not filesystem.exists(path) or filesystem.isDirectory(path) then return nil, "file not found" end
    local lineCount = math.max(1, math.min(200, math.floor(tonumber(args.lines) or 50)))
    local size = filesystem.size(path)
    local f, openErr = io.open(path, "rb")
    if not f then return nil, tostring(openErr) end
    local start = math.max(0, size - 65536)
    f:seek("set", start)
    local data = f:read("*a") or ""
    f:close()
    if start > 0 then
      local firstNewline = data:find("\n", 1, true)
      if firstNewline then data = data:sub(firstNewline + 1) end
    end
    local lines = {}
    for line in data:gmatch("[^\r\n]+") do
      lines[#lines + 1] = line
    end
    local output = {}
    local first = math.max(1, #lines - lineCount + 1)
    for i = first, #lines do output[#output + 1] = lines[i] end
    return {path = path, lines = #output, text = table.concat(output, "\n"), truncated = start > 0}

  elseif operation == "write_chunk" then
    local path, err = canonicalPath(args.path)
    if not path then return nil, err end
    if protectedPath(path) or path == "/" then return nil, "protected destination" end
    local transfer = tostring(args.transfer_id or "")
    if not transfer:match("^[%w_-]+$") or #transfer > 40 then return nil, "invalid transfer ID" end
    local offset = tonumber(args.offset)
    local total = tonumber(args.total)
    local data = args.data
    if not offset or not total or type(data) ~= "string" then return nil, "invalid upload chunk" end
    offset, total = math.floor(offset), math.floor(total)
    if total < 0 or total > MAX_UPLOAD or offset < 0 or #data > MAX_READ then return nil, "upload size/offset limit exceeded" end
    if offset + #data > total then return nil, "chunk exceeds declared file size" end
    local parent = filesystem.path(path)
    local base = filesystem.name(path)
    if not parent or parent == "" then parent = "/" end
    if not filesystem.exists(parent) or not filesystem.isDirectory(parent) then return nil, "destination directory does not exist" end
    local sessionKey = clientId .. ":" .. transfer
    local session = uploads[sessionKey]
    if not session then
      if offset ~= 0 then return nil, "first upload chunk must start at offset zero" end
      if filesystem.isDirectory(path) then return nil, "destination is a directory" end
      local temp = (parent == "/" and "" or parent) .. "/." .. base .. ".gsa-" .. transfer .. ".part"
      os.remove(temp)
      local f, createErr = io.open(temp, "wb")
      if not f then return nil, tostring(createErr) end
      f:close()
      session = {path = path, temp = temp, received = 0, total = total}
      uploads[sessionKey] = session
    end
    if session.path ~= path or session.total ~= total or session.received ~= offset then
      return nil, "upload offset/session mismatch"
    end
    local f, writeErr = io.open(session.temp, "ab")
    if not f then return nil, tostring(writeErr) end
    f:write(data)
    f:close()
    session.received = session.received + #data
    if args.final == true then
      if session.received ~= session.total then
        return nil, "final chunk received before declared size"
      end
      local backup = path .. ".gsa-backup"
      if filesystem.exists(backup) then filesystem.remove(backup) end
      local hadOld = filesystem.exists(path)
      if hadOld then
        local moved, moveErr = os.rename(path, backup)
        if not moved then return nil, "cannot make backup: " .. tostring(moveErr) end
      end
      local moved, moveErr = os.rename(session.temp, path)
      if not moved then
        if hadOld then os.rename(backup, path) end
        return nil, "cannot commit file: " .. tostring(moveErr)
      end
      uploads[sessionKey] = nil
      audit("INFO", "remote file replaced", path)
      return {path = path, bytes = session.received, committed = true, backup = hadOld and backup or nil}
    end
    return {path = path, received = session.received, total = session.total, committed = false}

  elseif operation == "mkdir" then
    local path, err = canonicalPath(args.path)
    if not path then return nil, err end
    if protectedPath(path) then return nil, "protected path" end
    local ok, reason = filesystem.makeDirectory(path)
    if not ok then return nil, tostring(reason or "mkdir failed") end
    audit("INFO", "remote directory created", path)
    return {path = path, created = true}

  elseif operation == "delete" then
    local path, err = canonicalPath(args.path)
    if not path then return nil, err end
    if protectedDelete(path) then return nil, "protected path; deletion refused" end
    if not filesystem.exists(path) then return nil, "path does not exist" end
    local ok, reason = filesystem.remove(path)
    if not ok then return nil, tostring(reason or "delete failed") end
    audit("WARNING", "remote path deleted", path)
    return {path = path, deleted = true}

  elseif operation == "rename" then
    local from, err = canonicalPath(args.from)
    if not from then return nil, err end
    local to, toErr = canonicalPath(args.to)
    if not to then return nil, toErr end
    if protectedPath(from) or protectedPath(to) or from == "/" or to == "/" then
      return nil, "protected rename path"
    end
    if not filesystem.exists(from) then return nil, "source does not exist" end
    if filesystem.exists(to) then return nil, "destination already exists" end
    local ok, reason = os.rename(from, to)
    if not ok then return nil, tostring(reason or "rename failed") end
    audit("INFO", "remote path renamed", from .. " -> " .. to)
    return {from = from, to = to, renamed = true}

  elseif operation == "exec" then
    local result, err = safeExec(tostring(args.command or ""))
    if not result then return nil, err end
    return result

  elseif operation == "reboot" then
    if args.confirm ~= "REBOOT " .. nodeId then
      return nil, "confirmation mismatch; expected REBOOT " .. nodeId
    end
    audit("WARNING", "remote reboot authorized", clientId)
    return {node_id = nodeId, rebooting = true}
  end

  return nil, "unknown operation"
end

local function handleMessage(_, localAddress, remoteAddress, port, distance, payload)
  if port ~= PORT or type(payload) ~= "string" or #payload > MAX_PACKET then return end
  local okOuter, envelope = pcall(serialization.unserialize, payload)
  if not okOuter or type(envelope) ~= "table" or type(envelope.body) ~= "string" or type(envelope.mac) ~= "string" then return end
  if not crypto.equal(crypto.hmac(key, envelope.body), envelope.mac) then return end

  local okBody, request = pcall(serialization.unserialize, envelope.body)
  if not okBody or type(request) ~= "table" then return end
  if request.protocol ~= PROTOCOL or request.network ~= networkId or request.kind ~= "request" then return end
  if type(request.client_id) ~= "string" or #request.client_id < 4 or #request.client_id > 80 then return end
  if type(request.sequence) ~= "number" or request.sequence < 1 then return end
  if type(request.request_id) ~= "string" or #request.request_id > 100 then return end
  if request.target ~= "*" and request.target ~= nodeId then return end
  -- A broadcast is permitted only for discovery; destructive operations must
  -- always be addressed to exactly one node.
  if request.target == "*" and request.operation ~= "discover" then return end

  local now = computer.uptime()
  local lastAt = lastRequestAt[request.client_id] or -10
  if now - lastAt < 0.03 then return end
  lastRequestAt[request.client_id] = now

  local last = tonumber(replay[request.client_id]) or 0
  if request.sequence <= last then return end
  replay[request.client_id] = request.sequence
  saveReplay()

  local result, err = perform(request.operation, request.args, request.client_id)
  local success = result ~= nil
  if success then
    audit("INFO", "remote operation " .. tostring(request.operation), request.client_id)
  else
    audit("WARNING", "remote operation denied/failed " .. tostring(request.operation), tostring(err))
  end
  sendReply(localAddress, remoteAddress, request, success, result, err)
  if success and request.operation == "reboot" then
    event.timer(0.25, function()
      computer.shutdown(true)
    end, 1)
  end
end

local listenerId = event.listen("modem_message", handleMessage)
if not listenerId then
  print("[REMOTE ADMIN] Could not register modem_message listener.")
  return
end

print("[REMOTE ADMIN] Agent " .. nodeId .. " ready on port " .. PORT ..
  " (authenticated; unencrypted; driver mode).")
audit("INFO", "remote admin agent started", VERSION)
