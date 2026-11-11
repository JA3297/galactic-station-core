-- Install as /etc/rc.d/station.lua, then run: rc station enable
-- Starts the station daemon in a detached OpenOS thread.
function start()
  local thread = require("thread")
  thread.create(function()
    dofile("/usr/bin/station.lua")
  end):detach()
end
