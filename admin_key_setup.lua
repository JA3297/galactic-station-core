-- Galactic Station remote administration key setup.
-- Run on the management computer with "generate" if a Tier 2+ Data Card
-- providing data.random() is installed. Run without arguments on other hosts.
-- The generated/entered secret must be copied identically to every agent host.
-- Never commit remote_admin.key to GitHub.

local component = require("component")
local filesystem = require("filesystem")
local path = "/etc/station/remote_admin.key"
filesystem.makeDirectory("/etc/station")

local function writeKey(key)
  if type(key) ~= "string" or #key < 64 then
    error("Secret must be at least 64 characters.")
  end
  local f, err = io.open(path, "wb")
  if not f then error("Cannot write key file: " .. tostring(err)) end
  f:write(key, "\n")
  f:close()
  print("Saved " .. path)
end

local mode = ...
if mode == "generate" then
  local data = component.data
  if not data or not data.random then
    error("No Data Card with random() found. Generate a 64+ character secret on your PC/password manager, then run this script without arguments.")
  end
  local raw = data.random(32)
  local key = (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  writeKey(key)
  print("")
  print("COPY THIS SECRET TO EVERY REMOTE ADMIN HOST:")
  print(key)
  print("")
  print("Do not put this value in GitHub or screenshots.")
else
  io.write("Paste the same 64+ character remote-admin secret: ")
  local first = io.read("*l")
  if not first or #first < 64 then error("Secret must be at least 64 characters.") end
  io.write("Paste it again to confirm: ")
  local second = io.read("*l")
  if first ~= second then error("Secrets did not match.") end
  writeKey(first)
end
