-- OpenOS rc service for archive-pair log collector.
-- IMPORTANT: Keep this service thread alive after dofile returns because
-- station_log_collector.lua registers its modem event listener in this thread.
-- Enable only on CORE-A4 and CORE-B4.

function start()
  local thread = require("thread")
  thread.create(function()
    local ok, err = pcall(function()
      dofile("/usr/lib/station_log_collector.lua")
    end)
    if not ok then
      print("[LOG COLLECTOR] Startup error: " .. tostring(err))
      return
    end

    print("[LOG COLLECTOR] Driver initialized; keeping listener thread alive.")
    local event = require("event")
    while true do
      local name = event.pull(1)
      if name == "interrupted" then
        print("[LOG COLLECTOR] Listener thread interrupted.")
        return
      end
    end
  end):detach()
end
