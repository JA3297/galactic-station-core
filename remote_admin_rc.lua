-- OpenOS rc service for authenticated remote administration.
-- Install as /etc/rc.d/remote_admin.lua.
-- The agent is a driver-mode event listener and intentionally returns once
-- event.listen callbacks have been registered.

local function recordStartup(message)
  pcall(require("filesystem").makeDirectory, "/var/station")
  local file = io.open("/var/station/remote_admin_service.log", "a")
  if file then
    file:write(tostring(os.date and os.date("%Y-%m-%d %H:%M:%S") or "time-unknown"),
      " ", tostring(message):gsub("[\\r\\n]", " "), "\n")
    file:close()
  end
end

function start()
  local thread = require("thread")
  local worker = thread.create(function()
    recordStartup("remote admin service thread started")
    local ok, err = pcall(function()
      dofile("/usr/lib/remote_admin_agent.lua")
    end)
    if not ok then
      recordStartup("REMOTE ADMIN STARTUP ERROR: " .. tostring(err))
      print("[REMOTE ADMIN] Startup error: " .. tostring(err))
    else
      recordStartup("remote admin agent script returned; inspect remote_admin_status.txt")
    end
  end)
  worker:detach()
end
