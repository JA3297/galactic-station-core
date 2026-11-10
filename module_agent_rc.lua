-- OpenOS rc service for the optional module communications agent.
-- Install as /etc/rc.d/module_agent.lua.
-- Enable with: rc module_agent enable

function start()
  local thread = require("thread")
  thread.create(function()
    dofile("/usr/bin/module_agent.lua")
  end):detach()
end
