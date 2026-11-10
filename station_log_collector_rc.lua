-- OpenOS rc service for archive-pair log collector.
-- Install as /etc/rc.d/station_log_collector.lua.
-- Enable only on CORE-A4 and CORE-B4:
--   rc station_log_collector enable

function start()
  local thread = require("thread")
  thread.create(function()
    dofile("/usr/lib/station_log_collector.lua")
  end):detach()
end
