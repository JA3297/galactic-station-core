-- Galactic Station v4 resident service.
-- One thread runs the single gsd event loop. No event.listen callbacks are used.
function start()
  local thread = require("thread")
  thread.create(function()
    dofile("/usr/bin/gsd.lua")
  end):detach()
end
