-- Galactic Station v4 cryptography
-- Requires a Tier 3 Data Card. Uses the card for SHA-256, AES and secure RNG.
-- Packets are encrypted and authenticated. No bit32/native bitwise dependency.
local component = require("component")
local serialization = require("serialization")

local dataAddress = component.list("data", true)()
if not dataAddress then error("Galactic Station v4 requires a Data Card.") end
local methods = component.methods(dataAddress)
local requiredMethods = {"sha256", "encrypt", "decrypt", "random"}
for _, method in ipairs(requiredMethods) do
  if methods[method] == nil then
    error("Data Card is missing required method: " .. method)
  end
end

-- Use component.invoke explicitly. This is the documented component API and
-- avoids relying on proxy-field lookup behavior on different OpenOS builds.
local function dataCall(method, ...)
  return component.invoke(dataAddress, method, ...)
end

local M = {}

local function xorByte(a, b)
  local value, place = 0, 1
  for _ = 1, 8 do
    local aa, bb = a % 2, b % 2
    if aa ~= bb then value = value + place end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    place = place * 2
  end
  return value
end

local function xorString(value, byte)
  local out = {}
  for i = 1, #value do
    out[i] = string.char(xorByte(value:byte(i), byte))
  end
  return table.concat(out)
end

local function hex(binary)
  return (binary:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

local function unhex(value)
  if type(value) ~= "string" or (#value % 2) ~= 0 or value:find("[^%x]") then
    return nil, "invalid hexadecimal string"
  end
  return (value:gsub("..", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

function M.randomHex(bytes)
  bytes = math.max(1, math.min(128, math.floor(tonumber(bytes) or 32)))
  return hex(dataCall("random", bytes))
end

function M.sha256(value)
  return dataCall("sha256", value)
end

function M.hmac(key, message)
  assert(type(key) == "string" and #key > 0, "HMAC key required")
  assert(type(message) == "string", "HMAC message must be a string")
  if #key > 64 then key = dataCall("sha256", key) end
  if #key < 64 then key = key .. string.rep("\0", 64 - #key) end
  local inner = xorString(key, 0x36)
  local outer = xorString(key, 0x5c)
  return dataCall("sha256", outer .. dataCall("sha256", inner .. message))
end

function M.equal(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local difference = 0
  for i = 1, #a do
    if a:byte(i) ~= b:byte(i) then difference = difference + 1 end
  end
  return difference == 0
end

local function aesKey(secret)
  -- OpenComputers Data Card AES uses a 128-bit (16-byte) key.
  -- SHA-256 returns 32 bytes, so truncate the derived digest to 16 bytes.
  return dataCall("sha256", "GALACTIC-STATION-V4-AES\0" .. secret):sub(1, 16)
end

function M.seal(secretHex, plaintext)
  local secret, err = unhex(secretHex)
  if not secret then return nil, err end
  if #secret < 32 then return nil, "station key must be at least 32 bytes" end
  if type(plaintext) ~= "string" then return nil, "plaintext must be a string" end

  local iv = dataCall("random", 16)
  local encryptedOK, cipher = pcall(data.encrypt, plaintext, aesKey(secret), iv)
  if not encryptedOK or type(cipher) ~= "string" then
    return nil, "Data Card encryption failed: " .. tostring(cipher)
  end

  local mac = M.hmac(secret, "GS4\0" .. iv .. cipher)
  return serialization.serialize({
    protocol = 4,
    iv = hex(iv),
    cipher = hex(cipher),
    mac = hex(mac)
  })
end

function M.open(secretHex, packetText)
  local secret, err = unhex(secretHex)
  if not secret then return nil, err end
  if #secret < 32 then return nil, "station key must be at least 32 bytes" end

  local ok, envelope = pcall(serialization.unserialize, packetText)
  if not ok or type(envelope) ~= "table" or envelope.protocol ~= 4 then
    return nil, "invalid v4 packet envelope"
  end

  local iv, ivErr = unhex(envelope.iv)
  local cipher, cipherErr = unhex(envelope.cipher)
  local mac, macErr = unhex(envelope.mac)
  if not iv or not cipher or not mac then
    return nil, ivErr or cipherErr or macErr or "malformed packet"
  end
  if #iv ~= 16 then return nil, "invalid AES initialization vector" end

  local expected = M.hmac(secret, "GS4\0" .. iv .. cipher)
  if not M.equal(expected, mac) then return nil, "authentication failed" end

  local decryptedOK, plaintext = pcall(data.decrypt, cipher, aesKey(secret), iv)
  if not decryptedOK or type(plaintext) ~= "string" then
    return nil, "Data Card decryption failed: " .. tostring(plaintext)
  end
  return plaintext
end

function M.selfTest()
  local sha = hex(dataCall("sha256", "abc"))
  local expectedSha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  local mac = hex(M.hmac("key", "The quick brown fox jumps over the lazy dog"))
  local expectedMac = "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
  local ok = sha == expectedSha and mac == expectedMac

  local key = M.randomHex(32)
  local sealed, sealErr = M.seal(key, "GALACTIC STATION V4 CRYPTO TEST")
  if not sealed then return false, sha, mac, sealErr end
  local plain, openErr = M.open(key, sealed)
  return ok and plain == "GALACTIC STATION V4 CRYPTO TEST", sha, mac, openErr
end

return M
