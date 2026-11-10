-- OpenOS rc service for authenticated remote administration agent.
-- Install as /etc/rc.d/remote_admin.lua and enable with:
--   rc remote_admin enable
--
-- The agent registers event.listen("modem_message") and returns; this is
-- intentional driver-mode operation. The station runtime continues to own
-- its event.pull loop and OpenOS dispatches modem events to registered listeners.

function start()
  local thread = require("thread")
  thread.create(function()
    dofile("/usr/lib/remote_admin_agent.lua")
  end):detach()
end
