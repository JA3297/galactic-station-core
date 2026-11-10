-- Compatibility wrapper for older installation instructions.
-- The former split installers are superseded by station_bootstrap.lua.
-- This wrapper downloads and starts the current role-aware installer.

local internet = require("internet")
local url = "https://raw.githubusercontent.com/JA3297/galactic-station-core/main/station_bootstrap.lua"
local ok, handle = pcall(internet.request, url)
if not ok or not handle then
  error("Could not download the current station bootstrap: " .. tostring(handle))
end

local chunks = {}
for chunk in handle do chunks[#chunks + 1] = chunk end
local path = "/tmp/station_bootstrap.lua"
local file, err = io.open(path, "wb")
if not file then error("Cannot write " .. path .. ": " .. tostring(err)) end
file:write(table.concat(chunks))
file:close()

dofile(path)
