-- Install as /etc/rc.d/witness.lua, then run: rc witness enable
function start()
  local thread = require("thread")
  thread.create(function()
    dofile("/usr/bin/witness.lua")
  end):detach()
end
