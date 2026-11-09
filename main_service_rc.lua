-- Install as /etc/rc.d/main_service.lua after the controller is tested.
-- Enable with: rc main_service enable
function start()
  local thread = require("thread")
  thread.create(function()
    dofile("/usr/bin/main_service.lua")
  end):detach()
end
