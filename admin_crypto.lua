-- Galactic Station remote administration cryptography.
-- Pure Lua 5.2 SHA-256 and HMAC-SHA256 using the standard bit32 library.
-- No Data Card is required. HMAC provides authenticity/integrity, not secrecy.

local bit = bit32
if not bit then
  error("admin_crypto requires Lua 5.2 bit32 support. Install a compatible OpenOS Lua 5.2 runtime.")
end

local band, bxor, bnot = bit.band, bit.bxor, bit.bnot
local rshift, rrotate = bit.rshift, bit.rrotate
local MOD = 4294967296

local K = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,
  0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,
  0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,
  0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,
  0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,
  0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,
  0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,
  0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,
  0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
}

local INITIAL = {
  0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
  0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
}

local function add(...)
  local total = 0
  for i = 1, select("#", ...) do
    total = total + (select(i, ...) or 0)
  end
  return total % MOD
end

local function word32(s, i)
  local a,b,c,d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function be32(n)
  n = n % MOD
  local a = math.floor(n / 16777216) % 256
  local b = math.floor(n / 65536) % 256
  local c = math.floor(n / 256) % 256
  local d = n % 256
  return string.char(a,b,c,d)
end

local function sha256(message)
  assert(type(message) == "string", "sha256 expects a string")
  local bitLength = #message * 8
  local high = math.floor(bitLength / MOD)
  local low = bitLength % MOD
  local zeroCount = (56 - ((#message + 1) % 64)) % 64
  local padded = message .. string.char(0x80) ..
    string.rep("\0", zeroCount) .. be32(high) .. be32(low)

  local H = {}
  for i = 1, 8 do H[i] = INITIAL[i] end

  for offset = 1, #padded, 64 do
    local block = padded:sub(offset, offset + 63)
    local W = {}
    for i = 1, 16 do W[i] = word32(block, (i - 1) * 4 + 1) end

    for i = 17, 64 do
      local x = W[i - 15]
      local y = W[i - 2]
      local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
      local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
      W[i] = add(W[i - 16], s0, W[i - 7], s1)
    end

    local a,b,c,d,e,f,g,h =
      H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8]

    for i = 1, 64 do
      local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = add(h, S1, ch, K[i], W[i])
      local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
      local maj = bxor(band(a,b), band(a,c), band(b,c))
      local t2 = add(S0, maj)
      h,g,f,e,d,c,b,a = g,f,e,add(d,t1),c,b,a,add(t1,t2)
    end

    H[1] = add(H[1],a)
    H[2] = add(H[2],b)
    H[3] = add(H[3],c)
    H[4] = add(H[4],d)
    H[5] = add(H[5],e)
    H[6] = add(H[6],f)
    H[7] = add(H[7],g)
    H[8] = add(H[8],h)
  end

  local out = {}
  for i = 1, 8 do out[i] = be32(H[i]) end
  return table.concat(out)
end

local function hmacSha256(key, message)
  assert(type(key) == "string" and #key > 0, "HMAC key is required")
  assert(type(message) == "string", "HMAC message must be a string")
  if #key > 64 then key = sha256(key) end
  key = key .. string.rep("\0", 64 - #key)

  local inner, outer = {}, {}
  for i = 1, 64 do
    local byte = key:byte(i)
    inner[i] = string.char(bxor(byte, 0x36))
    outer[i] = string.char(bxor(byte, 0x5c))
  end
  return sha256(table.concat(outer) .. sha256(table.concat(inner) .. message))
end

local function hex(binary)
  return (binary:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

local function equal(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do diff = bit.bor(diff, bxor(a:byte(i), b:byte(i))) end
  return diff == 0
end

local M = {
  sha256 = sha256,
  hmac = hmacSha256,
  hex = hex,
  equal = equal
}

function M.selfTest()
  local digest = hex(sha256("abc"))
  local expectedDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  local mac = hex(hmacSha256("key", "The quick brown fox jumps over the lazy dog"))
  local expectedMac = "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
  return digest == expectedDigest and mac == expectedMac, digest, mac
end

return M
