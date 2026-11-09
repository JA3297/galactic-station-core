-- Station network helper for module-local OpenComputers programs.
-- Install as /usr/lib/station_api.lua. See /etc/station/module.lua template.
local M = {}
local component = require("component")
local computer = require("computer")
local event = require("event")
local serialization = require("serialization")

local CFG = dofile("/etc/station/module.lua")
local PORT = 45821
local MAGIC = "GALACTIC_STATION"
local PROTOCOL = 1
local modems = {}
local sequence = 0

for address in component.list("modem", true) do
  local modem = component.proxy(address)
  pcall(modem.open, PORT)
  table.insert(modems, modem)
end
if #modems == 0 then error("No modem attached") end

local function send(kind, data)
  sequence = sequence + 1
  local packet = {
    magic = MAGIC, protocol = PROTOCOL, network = CFG.network_id,
    sender = CFG.module_id, sender_role = "module", pair_id = "MODULE",
    side = "M", sequence = sequence, sent_at = computer.uptime(),
    kind = kind, data = data or {}
  }
  local payload = serialization.serialize(packet)
  local sent = false
  for _, modem in ipairs(modems) do
    local ok, result = pcall(modem.broadcast, PORT, payload)
    if ok and result then sent = true end
  end
  return sent
end

function M.telemetry(field, value, unit, resource)
  assert(type(field) == "string", "field must be a string")
  send("telemetry", {module_id = CFG.module_id, field = field, value = value,
    unit = unit, resource = resource})
end

function M.event(name, severity, detail)
  send("station_event", {event = name, severity = severity or "INFO", detail = detail or "", module_id = CFG.module_id})
end

function M.heartbeat()
  send("node_heartbeat", {active = true, state = "LOCAL_AUTONOMOUS", services = {"module_agent"},
    uptime = computer.uptime(), free_memory = computer.freeMemory(), total_memory = computer.totalMemory()})
end

function M.requestAccess(operator, permission, target, requestId)
  requestId = requestId or (CFG.module_id .. "-" .. tostring(math.floor(computer.uptime() * 1000)))
  send("access_request", {request_id = requestId, requester = CFG.module_id,
    operator = operator, permission = permission, target = target})
  return requestId
end

function M.command(operator, requestId, approvalId, target, action, args)
  assert(type(approvalId) == "string", "approvalId is required")
  return send("command_request", {operator = operator, requester = CFG.module_id,
    request_id = requestId, approval_id = approvalId, target = target,
    action = action, args = args or {}})
end

function M.requestStatus(requestId)
  send("status_request", {request_id = requestId or "status-" .. tostring(computer.uptime()), requester = CFG.module_id})
end

function M.pull(timeout)
  local name, localAddress, remoteAddress, port, distance, payload = event.pull(timeout or 1, "modem_message")
  if name ~= "modem_message" or port ~= PORT or type(payload) ~= "string" then return nil end
  local ok, packet = pcall(serialization.unserialize, payload)
  if not ok or type(packet) ~= "table" or packet.magic ~= MAGIC or
     packet.protocol ~= PROTOCOL or packet.network ~= CFG.network_id then return nil end
  if packet.kind == "command_dispatch" then
    if packet.sender_role ~= "command" or packet.pair_id ~= "PAIR-CMD" or
       not packet.data or packet.data.target ~= CFG.module_id then return nil end
  end
  return packet
end

function M.moduleId() return CFG.module_id end
return M
