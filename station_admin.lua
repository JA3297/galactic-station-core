-- Galactic Station authenticated management console.
-- OpenOS / OpenComputers Lua 5.2.
--
-- Commands: help, discover, nodes, use, info, pwd, ls, cd, cat, get, put,
-- mkdir, rm, mv, exec, reboot, update, logs, collect, exit.
--
-- Requires an Internet Card only for the GitHub "update" command.
-- Requires /etc/station/remote_admin.key, shared with managed nodes.
-- HMAC-SHA256 authenticates traffic; modem packets are not encrypted.

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local serialization = require("serialization")
local crypto = require("admin_crypto")

local PORT = 45822
local PROTOCOL = 1
local CHUNK_SIZE = 1000
local MAX_FILE = 2097152
local REPO_BASE = "https://raw.githubusercontent.com/JA3297/galactic-station-core/main/"
local MANIFEST_URL = REPO_BASE .. "deploy/manifest.lua"
local NETWORK_ID = "GALACTIC-STATION-01"

for _, configPath in ipairs({"/etc/station/admin.lua", "/etc/station/node.lua", "/etc/station/module.lua", "/etc/station/witness.lua"}) do
  local ok, cfg = pcall(dofile, configPath)
  if ok and type(cfg) == "table" and type(cfg.network_id) == "string" then
    NETWORK_ID = cfg.network_id
    break
  end
end

local function readAll(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function writeAll(path, data)
  local parent = filesystem.path(path)
  if parent and parent ~= "" then filesystem.makeDirectory(parent) end
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(data)
  f:close()
  return true
end

local key = readAll("/etc/station/remote_admin.key")
if not key then
  error("Missing /etc/station/remote_admin.key. Install the same secret used by remote agents.")
end
key = key:gsub("[\r\n]+$", "")
if #key < 32 then error("Remote admin key must contain at least 32 characters.") end
local selfTest = crypto.selfTest()
if not selfTest then error("Admin crypto self-test failed.") end

filesystem.makeDirectory("/var/station")
local clientId = readAll("/etc/station/admin_client_id")
if not clientId then
  clientId = "ADMIN-" .. computer.address():sub(1, 20)
  local saved, saveErr = writeAll("/etc/station/admin_client_id", clientId)
  if not saved then error("Cannot persist admin client ID: " .. tostring(saveErr)) end
end
clientId = clientId:gsub("[\r\n]+$", "")
if not clientId:match("^[%w_-]+$") then error("Invalid /etc/station/admin_client_id.") end

local sequence = tonumber(readAll("/var/station/admin_client_seq")) or 0
local function nextSequence()
  sequence = sequence + 1
  local ok, err = writeAll("/var/station/admin_client_seq", tostring(sequence))
  if not ok then error("Cannot persist admin request sequence: " .. tostring(err)) end
  return sequence
end

local modems = {}
for address in component.list("modem", true) do
  local modem = component.proxy(address)
  pcall(modem.open, PORT)
  modems[#modems + 1] = modem
end
if #modems == 0 then error("No modem attached to this management computer.") end

local inbox = {}
local nodes = {}
local diagnostic = {
  events = 0, port_packets = 0, bad_payload = 0, bad_mac = 0,
  bad_reply = 0, authenticated_replies = 0
}
local keyFingerprint = crypto.hex(crypto.sha256(key)):sub(1, 16)
local selected = nil
local cwd = "/"

local function seal(body)
  local raw = serialization.serialize(body)
  return serialization.serialize({body = raw, mac = crypto.hmac(key, raw)})
end

local function onMessage(_, localAddress, remoteAddress, port, distance, payload)
  diagnostic.events = diagnostic.events + 1
  if port ~= PORT then return end
  diagnostic.port_packets = diagnostic.port_packets + 1
  if type(payload) ~= "string" or #payload > 7000 then
    diagnostic.bad_payload = diagnostic.bad_payload + 1
    return
  end
  local ok, envelope = pcall(serialization.unserialize, payload)
  if not ok or type(envelope) ~= "table" or type(envelope.body) ~= "string" or type(envelope.mac) ~= "string" then
    diagnostic.bad_payload = diagnostic.bad_payload + 1
    return
  end
  if not crypto.equal(crypto.hmac(key, envelope.body), envelope.mac) then
    diagnostic.bad_mac = diagnostic.bad_mac + 1
    return
  end
  local bodyOK, body = pcall(serialization.unserialize, envelope.body)
  if not bodyOK or type(body) ~= "table" or body.protocol ~= PROTOCOL or
     body.network ~= NETWORK_ID or body.kind ~= "reply" or body.client_id ~= clientId then
    diagnostic.bad_reply = diagnostic.bad_reply + 1
    return
  end
  diagnostic.authenticated_replies = diagnostic.authenticated_replies + 1
  local list = inbox[body.request_id] or {}
  list[#list + 1] = {body = body, address = remoteAddress, local_address = localAddress}
  inbox[body.request_id] = list
end

local listenerId = event.listen("modem_message", onMessage)
local legacyListenerId = event.listen("modem", onMessage)
if not listenerId and not legacyListenerId then error("Could not register management response listener.") end

local function sendRequest(target, operation, args, timeout, collectAll)
  local seq = nextSequence()
  local requestId = clientId .. "-" .. tostring(seq)
  local body = {
    protocol = PROTOCOL, network = NETWORK_ID,
    kind = "request", client_id = clientId, sequence = seq,
    request_id = requestId, target = target or "*",
    operation = operation, args = args or {}
  }
  local payload = seal(body)
  local sent = false

  if not target or target == "*" then
    for _, modem in ipairs(modems) do
      local ok, result = pcall(modem.broadcast, PORT, payload)
      if ok and result then sent = true end
    end
  else
    local node = nodes[target]
    if not node or not node.address then
      return nil, "unknown node. Run 'discover' first."
    end
    for _, modem in ipairs(modems) do
      local ok, result = pcall(modem.send, node.address, PORT, payload)
      if ok and result then sent = true end
    end
  end

  if not sent then return nil, "modem could not send the request" end
  local deadline = computer.uptime() + (timeout or 5)
  repeat
    event.pull(0.1)
    local replies = inbox[requestId]
    if replies and #replies > 0 then
      if collectAll then
        -- Continue collecting discovery replies until the timeout expires.
      else
        inbox[requestId] = nil
        local response = replies[1].body
        if not response.ok then return nil, response.error or "remote operation failed" end
        return response.result, nil, replies[1].address
      end
    end
  until computer.uptime() >= deadline

  local replies = inbox[requestId]
  inbox[requestId] = nil
  if collectAll and replies then return replies end
  if replies and replies[1] then
    local response = replies[1].body
    if not response.ok then return nil, response.error or "remote operation failed" end
    return response.result, nil, replies[1].address
  end
  return nil, "timed out waiting for " .. tostring(target or "station")
end

local function discover()
  print("Discovering authenticated station nodes...")
  diagnostic.events, diagnostic.port_packets = 0, 0
  diagnostic.bad_payload, diagnostic.bad_mac = 0, 0
  diagnostic.bad_reply, diagnostic.authenticated_replies = 0, 0
  local replies, err = sendRequest("*", "discover", {}, 5.0, true)
  if not replies then
    print("Discovery failed: " .. tostring(err))
    print(string.format("Diagnostics: events=%d port45822=%d badPayload=%d badHMAC=%d badReply=%d",
      diagnostic.events, diagnostic.port_packets, diagnostic.bad_payload,
      diagnostic.bad_mac, diagnostic.bad_reply))
    print("Manager network=" .. NETWORK_ID .. " key fingerprint=" .. keyFingerprint)
    return
  end
  local count = 0
  for _, entry in ipairs(replies) do
    local info = entry.body.result
    if type(info) == "table" and type(info.node_id) == "string" then
      nodes[info.node_id] = {address = entry.address, info = info, seen = computer.uptime()}
      count = count + 1
    end
  end
  print("Authenticated nodes discovered: " .. tostring(count))
  for id, node in pairs(nodes) do
    print(string.format("  %-22s %-9s %-14s %s", id,
      tostring(node.info.kind), tostring(node.info.role or "-"),
      tostring(node.info.pair_id or node.info.network_id)))
  end
end

local function getSelected()
  if not selected then return nil, "select a node first: use CORE-A1" end
  if not nodes[selected] then return nil, "node is not in discovery cache; run discover" end
  return selected
end

local function remote(operation, args, timeout)
  local target, err = getSelected()
  if not target then return nil, err end
  return sendRequest(target, operation, args, timeout or 5, false)
end

local function remoteRead(path, onChunk)
  local offset, size = 0, nil
  repeat
    local result, err = remote("read", {path = path, offset = offset, limit = CHUNK_SIZE}, 8)
    if not result then return false, err end
    if size == nil then
      size = result.size
      if size and size > MAX_FILE then return false, "remote file exceeds 2 MiB transfer limit" end
    end
    if type(result.data) ~= "string" then return false, "invalid read response" end
    if onChunk then onChunk(result.data) end
    offset = offset + #result.data
    if result.eof then break end
    if #result.data == 0 then return false, "remote read made no progress" end
  until offset >= (size or 0)
  return true, size or offset
end

local function collectDiagnostics(nodeId, outputRoot)
  local node = nodes[nodeId]
  if not node then return false, "unknown node" end
  local previousSelected = selected
  selected = nodeId

  outputRoot = outputRoot or ("/home/station-diagnostics/" .. nodeId)
  filesystem.makeDirectory(outputRoot)

  local files = {
    {path = "/var/station/events.log", name = "events-last.txt", lines = 150},
    {path = "/var/station/log-spool/active.log", name = "local-spool-last.txt", lines = 100},
    {path = "/var/station/logs/station.log", name = "central-archive-last.txt", lines = 150}
  }
  local saved = 0

  for _, item in ipairs(files) do
    local result, err = remote("tail", {path = item.path, lines = item.lines}, 8)
    if result and type(result.text) == "string" then
      local path = outputRoot .. "/" .. item.name
      local ok, writeErr = writeAll(path, result.text .. "\n")
      if ok then
        saved = saved + 1
        print("Saved " .. path)
      else
        print("Local write failed for " .. path .. ": " .. tostring(writeErr))
      end
    else
      print("Skipped " .. item.path .. ": " .. tostring(err))
    end
  end

  local snapshotPath = "/var/station/main_service_snapshot.txt"
  local stat = remote("stat", {path = snapshotPath}, 6)
  if stat and stat.exists and not stat.directory and stat.size <= 262144 then
    local chunks = {}
    local ok, err = remoteRead(snapshotPath, function(chunk) chunks[#chunks + 1] = chunk end)
    if ok then
      local path = outputRoot .. "/main-service-snapshot.txt"
      local writeOK, writeErr = writeAll(path, table.concat(chunks))
      if writeOK then
        saved = saved + 1
        print("Saved " .. path)
      else
        print("Local write failed: " .. tostring(writeErr))
      end
    else
      print("Snapshot download failed: " .. tostring(err))
    end
  end

  local info = node.info or {}
  local infoLines = {
    "GALACTIC STATION DIAGNOSTIC EXPORT",
    "Node: " .. tostring(nodeId),
    "Kind: " .. tostring(info.kind),
    "Role: " .. tostring(info.role),
    "Pair: " .. tostring(info.pair_id),
    "Agent version: " .. tostring(info.agent_version),
    "Computer address: " .. tostring(info.computer_address),
    "Collected from manager uptime: " .. tostring(computer.uptime())
  }
  local infoOK, infoErr = writeAll(outputRoot .. "/node-info.txt", table.concat(infoLines, "\n") .. "\n")
  if infoOK then saved = saved + 1 else print("Could not save node info: " .. tostring(infoErr)) end

  selected = previousSelected
  print("Diagnostic export complete: " .. tostring(saved) .. " file(s) in " .. outputRoot)
  return true, outputRoot
end

local function uploadData(remotePath, data)
  if #data > MAX_FILE then return false, "file exceeds 2 MiB transfer limit" end
  local transferId = "T" .. tostring(nextSequence()) .. "X" .. tostring(math.floor(computer.uptime() * 1000))
  local offset = 0
  repeat
    local chunk = data:sub(offset + 1, math.min(#data, offset + CHUNK_SIZE))
    local final = offset + #chunk >= #data
    local result, err = remote("write_chunk", {
      path = remotePath, transfer_id = transferId, offset = offset,
      total = #data, data = chunk, final = final
    }, 10)
    if not result then return false, err end
    offset = offset + #chunk
    if #data == 0 then break end
  until offset >= #data
  return true, #data
end

local function downloadRaw(url)
  local loaded, internet = pcall(require, "internet")
  if not loaded then return nil, "Internet Card library unavailable: " .. tostring(internet) end
  local ok, handle = pcall(internet.request, url)
  if not ok or not handle then return nil, tostring(handle or "HTTP request failed") end
  local pieces, size = {}, 0
  local readOK, readErr = pcall(function()
    for chunk in handle do
      size = size + #chunk
      if size > MAX_FILE then error("download exceeds 2 MiB limit") end
      pieces[#pieces + 1] = chunk
    end
  end)
  if not readOK then return nil, tostring(readErr) end
  return table.concat(pieces)
end

local manifestCache
local function getManifest()
  if manifestCache then return manifestCache end
  local text, err = downloadRaw(REPO_BASE .. "deploy/manifest.lua")
  if not text then return nil, err end
  local loader, loadErr = load(text, "@station-manifest", "t", {})
  if not loader then return nil, loadErr end
  local ok, manifest = pcall(loader)
  if not ok or type(manifest) ~= "table" then return nil, "invalid deployment manifest" end
  manifestCache = manifest
  return manifest
end

local function updateNode(nodeId)
  local node = nodes[nodeId]
  if not node then print("Unknown node: " .. nodeId); return end
  local previousSelected = selected
  selected = nodeId
  local function restoreSelection() selected = previousSelected end

  local manifest, err = getManifest()
  if not manifest then
    print("Cannot load GitHub manifest: " .. tostring(err))
    restoreSelection()
    return
  end

  local info = node.info
  local files = {}
  local function addAll(items)
    for _, item in ipairs(items or {}) do files[#files + 1] = item end
  end
  addAll(manifest.common)
  if info.kind == "core" then
    addAll(manifest.roles and manifest.roles.core)
  elseif info.kind == "witness" then
    addAll(manifest.roles and manifest.roles.witness)
  else
    print("No v4 deployment profile for " .. tostring(info.kind))
    restoreSelection()
    return
  end

  print("Staging version " .. tostring(manifest.version) .. " on " .. nodeId)
  for index, item in ipairs(files) do
    io.write(string.format("[%d/%d] %s -> %s ... ", index, #files, item.source, item.destination))
    local data, downloadErr = downloadRaw(REPO_BASE .. item.source)
    if not data then
      print("DOWNLOAD FAILED: " .. tostring(downloadErr))
      restoreSelection()
      return
    end
    local ok, uploadErr = uploadData(item.destination, data)
    if not ok then
      print("UPLOAD FAILED: " .. tostring(uploadErr))
      restoreSelection()
      return
    end
    print(tostring(#data) .. " bytes")
  end
  restoreSelection()
  print("Update files staged on " .. nodeId .. ". Running processes are NOT restarted.")
  print("Review the pair/role, then reboot or restart it during a maintenance window.")
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

local function printHelp()
  print("")
  print("GALACTIC STATION REMOTE ADMIN")
  print("  discover                 find authenticated nodes")
  print("  nodes                    list discovered nodes")
  print("  use <node-id>            select a remote computer")
  print("  info                     show selected node details")
  print("  pwd | cd <path>          remote working directory")
  print("  ls [path]                list remote directory")
  print("  cat <path>               display remote text file (small files)")
  print("  get <remote> <local>     download a remote file")
  print("  put <local> <remote>     upload a local file")
  print("  mkdir <path>             create remote directory")
  print("  rm <path>                delete after typed confirmation")
  print("  mv <from> <to>           rename/move remote path")
  print("  exec uptime|memory|components|mounts|services")
  print("  reboot                   reboot after exact node-specific confirmation")
  print("  update <node-id|all>     stage files from the GitHub manifest")
  print("  logs [lines]             show the last lines of the central archive log")
  print("  collect <node-id|all>     save local diagnostic bundle(s)")
  print("  help | exit")
  print("")
  print("Paths with spaces may be enclosed in quotes.")
end

print("============================================================")
print(" GALACTIC STATION | REMOTE ADMIN CONSOLE")
print("============================================================")
print("Client: " .. clientId)
print("Network: " .. NETWORK_ID .. " | key fingerprint: " .. keyFingerprint)
print("Network port: " .. PORT .. " | HMAC authenticated | not encrypted")
print("Type 'help'. Run 'discover' to find managed computers.")
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
    printHelp()
  elseif cmd == "discover" then
    discover()
  elseif cmd == "nodes" then
    for id, node in pairs(nodes) do
      print(string.format("%-22s %-9s %-14s uptime %.0fs",
        id, tostring(node.info.kind), tostring(node.info.role or "-"),
        tonumber(node.info.uptime) or 0))
    end
  elseif cmd == "use" or cmd == "select" then
    if not w[2] then print("Usage: use CORE-A1")
    elseif not nodes[w[2]] then print("Node not discovered. Run discover.")
    else selected = w[2]; cwd = "/"; print("Selected " .. selected) end
  elseif cmd == "info" then
    local result, err = remote("info", {})
    if not result then print("ERROR: " .. tostring(err))
    else
      for k, v in pairs(result) do print(tostring(k) .. ": " .. tostring(v)) end
    end
  elseif cmd == "pwd" then
    print(cwd)
  elseif cmd == "cd" then
    local path = w[2] or "/"
    if path:sub(1,1) ~= "/" then path = (cwd == "/" and "" or cwd) .. "/" .. path end
    local result, err = remote("stat", {path = path})
    if not result then print("ERROR: " .. tostring(err))
    elseif not result.exists or not result.directory then print("Not a directory.")
    else cwd = path:gsub("/+$",""); if cwd == "" then cwd = "/" end end
  elseif cmd == "ls" then
    local path = w[2] or cwd
    if path:sub(1,1) ~= "/" then path = (cwd == "/" and "" or cwd) .. "/" .. path end
    local offset, finished = 0, false
    local firstPage = true
    while not finished do
      local result, err = remote("list", {path = path, offset = offset, limit = 24})
      if not result then
        print("ERROR: " .. tostring(err))
        finished = true
      else
        if firstPage then
          print("Directory: " .. result.path .. " (" .. tostring(result.total) .. " entries)")
          firstPage = false
        end
        for _, entry in ipairs(result.entries or {}) do
          local name = tostring(entry.name):gsub("/+$","")
          print(string.format("%-38s %s", name, entry.directory and "<DIR>" or tostring(entry.size)))
        end
        if result.next_offset then
          offset = result.next_offset
        else
          finished = true
        end
        if result.truncated and not result.next_offset then
          print("[listing truncated at remote scan limit]")
        end
      end
    end
  elseif cmd == "cat" then
    if not w[2] then print("Usage: cat /path/to/file")
    else
      local path = w[2]
      if path:sub(1,1) ~= "/" then path = (cwd == "/" and "" or cwd) .. "/" .. path end
      local ok, err = remoteRead(path, function(chunk) io.write(chunk) end)
      if not ok then print("ERROR: " .. tostring(err)) else print("") end
    end
  elseif cmd == "get" then
    if not w[2] or not w[3] then print("Usage: get <remote-path> <local-path>")
    else
      local path = w[2]
      if path:sub(1,1) ~= "/" then path = (cwd == "/" and "" or cwd) .. "/" .. path end
      local chunks = {}
      local ok, result = remoteRead(path, function(chunk) chunks[#chunks + 1] = chunk end)
      if not ok then print("ERROR: " .. tostring(result))
      else
        local saved, saveErr = writeAll(w[3], table.concat(chunks))
        if saved then print("Downloaded " .. tostring(result) .. " bytes to " .. w[3])
        else print("Local write failed: " .. tostring(saveErr)) end
      end
    end
  elseif cmd == "put" then
    if not w[2] or not w[3] then print("Usage: put <local-path> <remote-path>")
    else
      local data = readAll(w[2])
      if not data then print("Cannot read local file: " .. w[2])
      else
        local path = w[3]
        if path:sub(1,1) ~= "/" then path = (cwd == "/" and "" or cwd) .. "/" .. path end
        local ok, result = uploadData(path, data)
        if ok then print("Uploaded " .. tostring(result) .. " bytes to " .. path)
        else print("UPLOAD FAILED: " .. tostring(result)) end
      end
    end
  elseif cmd == "mkdir" then
    if not w[2] then print("Usage: mkdir <path>")
    else
      local path = w[2]
      if path:sub(1,1) ~= "/" then path = (cwd == "/" and "" or cwd) .. "/" .. path end
      local result, err = remote("mkdir", {path = path})
      print(result and ("Created " .. path) or ("ERROR: " .. tostring(err)))
    end
  elseif cmd == "rm" then
    if not w[2] then print("Usage: rm <path>")
    else
      local path = w[2]
      if path:sub(1,1) ~= "/" then path = (cwd == "/" and "" or cwd) .. "/" .. path end
      io.write("Type DELETE to remove " .. path .. ": ")
      if io.read("*l") == "DELETE" then
        local result, err = remote("delete", {path = path})
        print(result and ("Deleted " .. path) or ("ERROR: " .. tostring(err)))
      else print("Cancelled.") end
    end
  elseif cmd == "mv" then
    if not w[2] or not w[3] then print("Usage: mv <from> <to>")
    else
      local from, to = w[2], w[3]
      if from:sub(1,1) ~= "/" then from = (cwd == "/" and "" or cwd) .. "/" .. from end
      if to:sub(1,1) ~= "/" then to = (cwd == "/" and "" or cwd) .. "/" .. to end
      local result, err = remote("rename", {from = from, to = to})
      print(result and "Rename complete." or ("ERROR: " .. tostring(err)))
    end
  elseif cmd == "exec" then
    local command = w[2] or ""
    local result, err = remote("exec", {command = command})
    if not result then print("ERROR: " .. tostring(err))
    elseif type(result) == "table" then
      for k, v in pairs(result) do
        if type(v) == "table" then print(tostring(k) .. ": " .. serialization.serialize(v))
        else print(tostring(k) .. ": " .. tostring(v)) end
      end
    else print(tostring(result)) end
  elseif cmd == "reboot" then
    local target, targetErr = getSelected()
    if not target then
      print("ERROR: " .. tostring(targetErr))
    else
      io.write("Type REBOOT " .. target .. " to confirm: ")
      if io.read("*l") == "REBOOT " .. target then
        local result, err = remote("reboot", {confirm = "REBOOT " .. target}, 8)
        if result then print(target .. " accepted the reboot request.")
        else print("REBOOT FAILED: " .. tostring(err)) end
      else
        print("Cancelled.")
      end
    end
  elseif cmd == "update" then
    if w[2] == "all" then
      local ids = {}
      for id in pairs(nodes) do ids[#ids + 1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do updateNode(id) end
    elseif w[2] then
      updateNode(w[2])
    else
      print("Usage: update <node-id|all>")
    end
  elseif cmd == "collect" then
    local target = w[2] or selected
    if target == "all" then
      local ids = {}
      for id in pairs(nodes) do ids[#ids + 1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do collectDiagnostics(id) end
    elseif not target then
      print("Usage: collect <node-id|all> (or select a node first)")
    else
      collectDiagnostics(target)
    end
  elseif cmd == "logs" then
    local count = math.max(1, math.min(200, tonumber(w[2]) or 50))
    local result, err = remote("tail", {path = "/var/station/logs/station.log", lines = count}, 8)
    if not result then
      print("ERROR: " .. tostring(err))
    else
      print("Log: " .. result.path .. " | last " .. tostring(result.lines) .. " lines")
      if result.truncated then print("[older part of file omitted]") end
      print(result.text or "")
    end
  else
    print("Unknown command. Type help.")
  end
end

event.ignore("modem_message", onMessage)
print("Remote administration console closed.")
