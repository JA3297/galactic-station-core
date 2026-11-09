-- OpenOS init service for Main Service Life Support Monitor.
-- Install as /etc/rc.d/main_service_monitor.lua
-- Enable with: rc main_service_monitor enable

function start()
  local thread = require("thread")
  thread.create(function()
    dofile("/usr/bin/main_service_monitor.lua")
  end):detach()
end
