-- Galactic Station HMAC/SHA-256 runtime verification.
-- Run after installing admin_crypto.lua:
--   lua /usr/bin/admin_crypto_test.lua

local crypto = require("admin_crypto")
local ok, sha, mac = crypto.selfTest()

print("Galactic Station cryptography self-test")
print("SHA-256 vector: " .. tostring(sha))
print("HMAC-SHA256 vector: " .. tostring(mac))

if not ok then
  print("FAILED: do not enable remote administration.")
  error("admin_crypto self-test failed")
end

local testA = crypto.hmac("secret-A", "station-test")
local testB = crypto.hmac("secret-B", "station-test")
if crypto.equal(testA, testB) then
  error("FAILED: HMAC key separation test failed")
end

print("Key separation: PASS")
print("All cryptography tests passed.")
