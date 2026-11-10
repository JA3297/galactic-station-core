-- OpenOS rc service for authenticated remote administration.
-- IMPORTANT: The listener registrations created by remote_admin_agent.lua
-- belong to this thread. Keep this thread alive after dofile returns.
-- OpenOS dispatches registered callbacks whenever this thread calls event.pull.

local function recordStartup(message)
  pcall(require("filesystem").makeDirectory, "/var/station")
  local file = io.open("/var/station/remote_admin_service.log", "a")
  if file then
    file:write(
      tostring(os.date and os.date("%Y-%m-%d %H:%M:%S") or "time-unknown"),
      " ", tostring(message):gsub("[\r\n]", " "), "\n"
    )
    file:close()
  end
end
function start()
  local thread = require("thread")
  thread.create(function()
    recordStartup("remote admin service thread started")

    local ok, err = pcall(function()
      dofile("/usr/lib/remote_admin_agent.lua")
    end)

    if not ok then
      recordStartup("REMOTE ADMIN STARTUP ERROR: " .. tostring(err))
      print("[REMOTE ADMIN] Startup error: " .. tostring(err))
      return
    end

    recordStartup("remote admin driver initialized; keeping listener thread alive")
    local event = require("event")
    while true do
      local name = event.pull(1)
      if name == "interrupted" then
        recordStartup("remote admin listener thread interrupted")
        return
      end
    end
  end):detach()
end
