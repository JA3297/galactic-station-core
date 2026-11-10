local crypto = require("gs_crypto")
local ok, sha, mac, err = crypto.selfTest()
print("GALACTIC STATION V4 DATA CARD CRYPTO TEST")
print("SHA-256: " .. tostring(sha))
print("HMAC-SHA256: " .. tostring(mac))
if err then print("AES error: " .. tostring(err)) end
if not ok then error("v4 cryptography test FAILED; do not provision the network") end
print("AES encrypt/decrypt: PASS")
print("All tests passed.")
