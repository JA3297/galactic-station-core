-- Galactic Station v4 central management console.
-- Run only on GS-HUB-01:
--   lua /usr/bin/gs.lua
--
-- Commands: help, discover, nodes, use, info, ls, cd, pwd, cat, get, put,
-- mkdir, rm, mv, exec, logs, collect, update, reboot, exit.
-- All remote packets use Tier 3 Data Card AES + HMAC on port 45840.

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local serialization = require("serialization")
local cfg = dofile("/etc/galactic/config.lua")
if cfg.role ~= "hub" then error("The v4 management console runs on GS-HUB-01 only.") end

local keyFile = assert(io.open("/etc/galactic/master.key", "rb"))
local key = keyFile:read("*a"):gsub("[\r\n]+$", "")
keyFile:close()
local crypto = require("gs_crypto")

local PORT = 45840
local BASE = "https://raw.githubusercontent.com/JA3297/galactic-station-core/main/v4/"
local CHUNK = 900
local MAX_FILE = 2097152
local clientId = cfg.node_id
local inbox = {}
local nodes = {}
local selected = nil
local cwd = "/"

local seqPath = "/var/galactic/state/manager_seq.txt"
filesystem.makeDirectory("/var/galactic/state")
local seqFile = io.open(seqPath, "r")
local sequence = seqFile and tonumber(seqFile:read("*a")) or 0
if seqFile then seqFile:close() end

local modems = {}
for address in component.list("modem", true) do
  local proxy = component.proxy(address)
  pcall(proxy.open, PORT)
  modems[#modems + 1] = {address = address, proxy = proxy}
end
if #modems == 0 then error("No wired Network Card detected.") end

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function writeFile(path, data)
  local parent = filesystem.path(path)
  if parent then filesystem.makeDirectory(parent) end
  local temp = path .. ".gs4tmp"
  local f, err = io.open(temp, "wb")
  if not f then return false, tostring(err) end
  f:write(data)
  f:close()
  if filesystem.exists(path) then
    local backup = path .. ".gs4bak"
    if filesystem.exists(backup) then filesystem.remove(backup) end
    local ok, why = os.rename(path, backup)
    if not ok then os.remove(temp); return false, tostring(why) end
  end
  local ok, why = os.rename(temp, path)
  if not ok then os.remove(temp); return false, tostring(why) end
  return true
end

local function nextSequence()
  sequence = sequence + 1
  local f, err = io.open(seqPath, "w")
  if not f then error("Cannot persist admin sequence: " .. tostring(err)) end
  f:write(tostring(sequence))
  f:close()
  return sequence
end

local function pack(message)
  message.protocol = 4
  message.station = cfg.station_id
  message.network = cfg.network_id
  message.sender = cfg.node_id
  message.uptime = computer.uptime()
  return crypto.seal(key, serialization.serialize(message))
end

local function sendPacket(address, message)
  local payload, err = pack(message)
  if not payload then return false, err end
  local sent = false
  for _, item in ipairs(modems) do
    local ok, result
    if address then
      ok, result = pcall(item.proxy.send, address, PORT, payload)
    else
      ok, result = pcall(item.proxy.broadcast, PORT, payload)
    end
    if ok and result then sent = true end
  end
  return sent
end

local function receiveOne(timeout, wantedId)
  local deadline = computer.uptime() + (timeout or 5)
  repeat
    local name, localAddress, remoteAddress, port, distance, payload = event.pull(0.15)
    if name == "modem_message" and port == PORT and type(payload) == "string" then
      local raw = crypto.open(key, payload)
      if raw then
        local ok, msg = pcall(serialization.unserialize, raw)
        if ok and type(msg) == "table" and msg.protocol == 4 and
           msg.station == cfg.station_id and msg.network == cfg.network_id then
          if msg.kind == "discover_reply" and msg.target == cfg.node_id then
            nodes[msg.info.node_id] = {
              address = remoteAddress, info = msg.info, seen = computer.uptime()
            }
            if not wantedId then return msg end
          elseif msg.kind == "reply" and msg.target == cfg.node_id and
                 msg.request_id == wantedId then
            return msg
          end
        end
      end
    end
  until computer.uptime() >= deadline
  return nil
end

local function discover()
  nodes = {}
  local requestId = cfg.node_id .. "-DISC-" .. tostring(nextSequence())
  local ok, err = sendPacket(nil, {
    kind = "discover", target = "*", request_id = requestId
  })
  if not ok then print("Broadcast failed: " .. tostring(err)); return end
  local deadline = computer.uptime() + 3
  while computer.uptime() < deadline do
    receiveOne(0.2, nil)
  end
  local count = 0
  for _ in pairs(nodes) do count = count + 1 end
  print("Discovered " .. tostring(count) .. " station node(s).")
  local ids = {}
  for id in pairs(nodes) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local n = nodes[id]
    print(string.format("%-16s %-13s %-9s %s",
      id, tostring(n.info.role), tostring(n.info.side), tostring(n.info.pair_id)))
  end
end

local function getSelected()
  if not selected then return nil, "select a node with: use GS-CORE-01" end
  if not nodes[selected] then return nil, "node not discovered; run discover" end
  return selected
end

local function remote(operation, args, timeout)
  local id, err = getSelected()
  if not id then return nil, err end
  local n = nodes[id]
  local seq = nextSequence()
  local requestId = cfg.node_id .. "-" .. tostring(seq)
  local ok, why = sendPacket(n.address, {
    kind = "admin", target = id, operation = operation,
    args = args or {}, seq = seq, request_id = requestId
  })
  if not ok then return nil, tostring(why or "send failed") end
  local reply = receiveOne(timeout or 6, requestId)
  if not reply then return nil, "timed out waiting for " .. id end
  if not reply.ok then return nil, reply.error or "remote operation failed" end
  return reply.result
end

local function remoteRead(path, onChunk)
  local offset, size = 0, nil
  repeat
    local result, err = remote("read", {path=path, offset=offset, limit=CHUNK}, 8)
    if not result then return false, err end
    if size == nil then
      size = result.size
      if size > MAX_FILE then return false, "remote file exceeds 2 MiB limit" end
    end
    if type(result.data) ~= "string" then return false, "invalid remote read response" end
    if onChunk then onChunk(result.data) end
    offset = offset + #result.data
    if result.eof then break end
    if #result.data == 0 then return false, "remote read stalled" end
  until offset >= size
  return true, size
end

local function uploadData(path, data)
  if #data > MAX_FILE then return false, "file exceeds 2 MiB limit" end
  local transferId = "U" .. tostring(nextSequence()) .. "X" .. tostring(math.floor(computer.uptime() * 1000))
  local offset = 0
  repeat
    local chunk = data:sub(offset + 1, math.min(#data, offset + CHUNK))
    local final = offset + #chunk >= #data
    local result, err = remote("write_chunk", {
      path = path, transfer_id = transferId, offset = offset,
      total = #data, data = chunk, final = final
    }, 8)
    if not result then return false, err end
    offset = offset + #chunk
    if #data == 0 then break end
  until offset >= #data
  return true, #data
end

local function downloadGitHub(source)
  local ok, internet = pcall(require, "internet")
  if not ok then return nil, "Internet Card library unavailable: " .. tostring(internet) end
  local requestOK, handle = pcall(internet.request, BASE .. source)
  if not requestOK or not handle then return nil, tostring(handle or "HTTP request failed") end
  local chunks, size = {}, 0
  local readOK, readErr = pcall(function()
    for chunk in handle do
      size = size + #chunk
      if size > MAX_FILE then error("GitHub file exceeds 2 MiB") end
      chunks[#chunks + 1] = chunk
    end
  end)
  if not readOK then return nil, tostring(readErr) end
  local body = table.concat(chunks)
  if #body == 0 then return nil, "empty GitHub file: " .. source end
  return body
end

local function loadManifest()
  local body, err = downloadGitHub("gs_manifest.lua")
  if not body then return nil, err end
  local loader, loadErr = load(body, "@gs_manifest", "t", {})
  if not loader then return nil, loadErr end
  local ok, manifest = pcall(loader)
  if not ok or type(manifest) ~= "table" then return nil, "invalid manifest" end
  return manifest
end

local function updateNode(id)
  local node = nodes[id]
  if not node then print("Unknown node. Run discover first."); return end
  local manifest, err = loadManifest()
  if not manifest then print("Manifest error: " .. tostring(err)); return end
  local files = {}
  for _, item in ipairs(manifest.common or {}) do files[#files + 1] = item end
  local roleFiles = manifest.roles and manifest.roles[node.info.role]
  for _, item in ipairs(roleFiles or {}) do files[#files + 1] = item end
  if #files == 0 then print("No deployment profile for " .. tostring(node.info.role)); return end

  print("Staging Galactic Station v" .. tostring(manifest.version) .. " on " .. id)
  local previous = selected
  selected = id
  for index, item in ipairs(files) do
    io.write(string.format("[%d/%d] %s -> %s ... ", index, #files, item.source, item.destination))
    local data, why = downloadGitHub(item.source)
    if not data then print("DOWNLOAD FAILED: " .. tostring(why)); selected = previous; return end
    local ok, result
    if id == cfg.node_id then
      ok, result = writeFile(item.destination, data)
    else
      ok, result = uploadData(item.destination, data)
    end
    if not ok then print("STAGE FAILED: " .. tostring(result)); selected = previous; return end
    print(tostring(#data) .. " bytes")
  end
  selected = previous
  print("Update staged. Running code was not hot-reloaded or restarted.")
end

local function collectNode(id)
  local previous = selected
  selected = id
  local outDir = "/home/galactic-diagnostics/" .. id
  filesystem.makeDirectory(outDir)
  local info = nodes[id] and nodes[id].info or {}
  local saved = 0

  local function collectFile(remotePath, localName)
    local stat, statErr = remote("stat", {path=remotePath}, 6)
    if not stat or not stat.exists or stat.directory or stat.size > MAX_FILE then
      print("Skipped " .. remotePath .. ": " .. tostring(statErr or "not present/too large"))
      return
    end
    local chunks = {}
    local ok, err = remoteRead(remotePath, function(chunk) chunks[#chunks + 1] = chunk end)
    if not ok then print("Read failed " .. remotePath .. ": " .. tostring(err)); return end
    local writeOK, writeErr = writeFile(outDir .. "/" .. localName, table.concat(chunks))
    if writeOK then saved = saved + 1; print("Saved " .. localName)
    else print("Local write failed: " .. tostring(writeErr)) end
  end

  collectFile("/var/galactic/logs/gs.log", "gs.log")
  collectFile("/var/galactic/logs/gs.log.1", "gs.log.1")
  collectFile("/var/galactic/logs/life_support_latest.dat", "life_support_latest.dat")

  local infoLines = {
    "GALACTIC STATION V4 DIAGNOSTIC",
    "node_id=" .. tostring(id),
    "role=" .. tostring(info.role),
    "side=" .. tostring(info.side),
    "pair_id=" .. tostring(info.pair_id),
    "uptime=" .. tostring(info.uptime),
    "manager_collected_at=" .. tostring(computer.uptime())
  }
  local infoOK = writeFile(outDir .. "/node-info.txt", table.concat(infoLines, "\n") .. "\n")
  if infoOK then saved = saved + 1 end
  selected = previous
  print("Collected " .. tostring(saved) .. " file(s) into " .. outDir)
end

local function splitWords(line)
  local words, token, quote, escape = {}, "", nil, false
  for i = 1, #line do
    local c = line:sub(i,i)
    if escape then token = token .. c; escape = false
    elseif c == "\\" then escape = true
    elseif quote then
      if c == quote then quote = nil else token = token .. c end
    elseif c == "'" or c == '"' then quote = c
    elseif c:match("%s") then
      if #token > 0 then words[#words + 1] = token; token = "" end
    else token = token .. c end
  end
  if #token > 0 then words[#words + 1] = token end
  return words
end

local function resolvePath(path)
  if not path then return cwd end
  if path:sub(1,1) == "/" then return path end
  return (cwd == "/" and "" or cwd) .. "/" .. path
end

local function help()
  print("")
  print("GALACTIC STATION V4 MANAGEMENT")
  print("  discover                  discover all four servers")
  print("  nodes                     list last discovered nodes")
  print("  use <node-id>             select a remote server")
  print("  info                      show selected node information")
  print("  pwd | cd <path>           remote working directory")
  print("  ls [path]                 remote directory browser")
  print("  cat <path>                display remote text")
  print("  get <remote> <local>      download a remote file")
  print("  put <local> <remote>      upload a local file")
  print("  mkdir <path>              create remote directory")
  print("  rm <path>                 delete with typed confirmation")
  print("  mv <from> <to>            rename/move a remote path")
  print("  exec <safe-command>       uptime, memory, status, components, mounts, services")
  print("  logs [lines]              view selected node's local log")
  print("  collect <node|all>         export diagnostics onto GS-HUB-01")
  print("  update <node-id>           stage current GitHub release on one server")
  print("  reboot                    reboot selected server with confirmation")
  print("  help | exit")
  print("")
end

print("============================================================")
print(" GALACTIC STATION V4 | COMMAND & RECORDS HUB")
print("============================================================")
print("Node: " .. cfg.node_id .. " | Port: " .. PORT .. " | AES + HMAC")
print("Use wired Network Card cabling. Type 'help'.")
print("")

while true do
  io.write((selected or "station") .. ":" .. cwd .. "> ")
  local line = io.read("*l")
  if not line then break end
  local w = splitWords(line)
  local cmd = w[1] and string.lower(w[1]) or ""

  if cmd == "" then
    -- no-op
  elseif cmd == "exit" or cmd == "quit" then
    break
  elseif cmd == "help" then
    help()
  elseif cmd == "discover" then
    discover()
  elseif cmd == "nodes" then
    local ids = {}
    for id in pairs(nodes) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local n = nodes[id]
      print(string.format("%-16s %-13s %-9s uptime %.0fs",
        id, tostring(n.info.role), tostring(n.info.side), tonumber(n.info.uptime) or 0))
    end
  elseif cmd == "use" then
    if not w[2] then print("Usage: use GS-CORE-01")
    elseif not nodes[w[2]] then print("Node not discovered; run discover.")
    else selected = w[2]; cwd = "/"; print("Selected " .. selected) end
  elseif cmd == "info" then
    local result, err = remote("info", {})
    if not result then print("ERROR: " .. tostring(err))
    else for k, v in pairs(result) do print(tostring(k) .. ": " .. tostring(v)) end end
  elseif cmd == "pwd" then
    print(cwd)
  elseif cmd == "cd" then
    local path = resolvePath(w[2])
    local stat, err = remote("stat", {path=path})
    if not stat then print("ERROR: " .. tostring(err))
    elseif not stat.exists or not stat.directory then print("Not a directory.")
    else cwd = path:gsub("/+$",""); if cwd == "" then cwd = "/" end end
  elseif cmd == "ls" then
    local path = resolvePath(w[2])
    local offset, finished = 0, false
    while not finished do
      local result, err = remote("list", {path=path, offset=offset, limit=24})
      if not result then print("ERROR: " .. tostring(err)); finished = true
      else
        print("Directory: " .. result.path .. " (" .. tostring(result.total) .. " entries)")
        for _, item in ipairs(result.entries or {}) do
          print(string.format("%-40s %s", tostring(item.name),
            item.directory and "<DIR>" or tostring(item.size)))
        end
        if result.next_offset then offset = result.next_offset else finished = true end
      end
    end
  elseif cmd == "cat" then
    if not w[2] then print("Usage: cat /path/file")
    else
      local ok, err = remoteRead(resolvePath(w[2]), function(chunk) io.write(chunk) end)
      if not ok then print("ERROR: " .. tostring(err)) else print("") end
    end
  elseif cmd == "get" then
    if not w[2] or not w[3] then print("Usage: get <remote> <local>")
    else
      local chunks = {}
      local ok, err = remoteRead(resolvePath(w[2]), function(chunk) chunks[#chunks + 1] = chunk end)
      if not ok then print("ERROR: " .. tostring(err))
      else
        local saved, saveErr = writeFile(w[3], table.concat(chunks))
        print(saved and ("Downloaded to " .. w[3]) or ("Local write error: " .. tostring(saveErr)))
      end
    end
  elseif cmd == "put" then
    if not w[2] or not w[3] then print("Usage: put <local> <remote>")
    else
      local body = readFile(w[2])
      if not body then print("Cannot read local file.")
      else
        local ok, result = uploadData(resolvePath(w[3]), body)
        print(ok and ("Uploaded " .. tostring(result) .. " bytes.") or ("UPLOAD FAILED: " .. tostring(result)))
      end
    end
  elseif cmd == "mkdir" then
    if not w[2] then print("Usage: mkdir <path>")
    else
      local result, err = remote("mkdir", {path=resolvePath(w[2])})
      print(result and "Directory created." or ("ERROR: " .. tostring(err)))
    end
  elseif cmd == "rm" then
    if not w[2] then print("Usage: rm <path>")
    else
      local path = resolvePath(w[2])
      io.write("Type DELETE to remove " .. path .. ": ")
      if io.read("*l") == "DELETE" then
        local result, err = remote("delete", {path=path})
        print(result and "Deleted." or ("ERROR: " .. tostring(err)))
      else print("Cancelled.") end
    end
  elseif cmd == "mv" then
    if not w[2] or not w[3] then print("Usage: mv <from> <to>")
    else
      local result, err = remote("rename", {from=resolvePath(w[2]), to=resolvePath(w[3])})
      print(result and "Renamed." or ("ERROR: " .. tostring(err)))
    end
  elseif cmd == "exec" then
    local result, err = remote("exec", {command=w[2] or ""})
    if not result then print("ERROR: " .. tostring(err))
    elseif type(result) == "table" then print(serialization.serialize(result))
    else print(tostring(result)) end
  elseif cmd == "logs" then
    local count = math.max(1, math.min(80, tonumber(w[2]) or 40))
    local result, err = remote("tail", {path="/var/galactic/logs/gs.log", lines=count})
    if not result then print("ERROR: " .. tostring(err))
    else print(result.text or "") end
  elseif cmd == "collect" then
    local target = w[2] or selected
    if target == "all" then
      local ids = {}
      for id in pairs(nodes) do ids[#ids + 1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do collectNode(id) end
    elseif not target then
      print("Usage: collect <node-id|all>")
    else collectNode(target) end
  elseif cmd == "update" then
    if not w[2] then print("Usage: update <node-id>")
    else updateNode(w[2]) end
  elseif cmd == "reboot" then
    local id, err = getSelected()
    if not id then print("ERROR: " .. tostring(err))
    else
      io.write("Type REBOOT " .. id .. " to confirm: ")
      if io.read("*l") == "REBOOT " .. id then
        local result, why = remote("reboot", {confirm="REBOOT " .. id}, 8)
        print(result and "Reboot accepted." or ("ERROR: " .. tostring(why)))
      else print("Cancelled.") end
    end
  else
    print("Unknown command. Type help.")
  end
end

print("GS v4 management console closed.")
