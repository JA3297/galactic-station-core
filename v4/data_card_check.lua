-- Galactic Station v4 Data Card diagnostic.
-- Safe: displays method names and tests the advertised Tier 2 crypto methods.
-- It never prints random bytes, keys, or stored secrets.
-- Run: lua /tmp/data_card_check.lua

local component = require("component")
local function line(s) print(tostring(s)) end
local function hexLength(value)
  if type(value) ~= "string" then return "not a string" end
  return tostring(#value) .. " bytes"
end

line("============================================================")
line(" GALACTIC STATION | DATA CARD DIAGNOSTIC")
line("============================================================")

local count = 0
for address, typeName in component.list("data", true) do
  count = count + 1
  line("")
  line("Data component #" .. tostring(count))
  line("Address: " .. tostring(address))
  line("Component type: " .. tostring(typeName))

  local methodOK, methods = pcall(component.methods, address)
  local methodSet = {}
  if methodOK and type(methods) == "table" then
    local names = {}
    for name, present in pairs(methods) do
      if present then
        methodSet[name] = true
        names[#names + 1] = tostring(name)
      end
    end
    table.sort(names)
    line("Methods reported by component.methods():")
    line("  " .. (#names > 0 and table.concat(names, ", ") or "(none)"))
  else
    line("component.methods() failed: " .. tostring(methods))
  end

  local proxyOK, proxy = pcall(component.proxy, address)
  if not proxyOK or type(proxy) ~= "table" then
    line("Proxy failed: " .. tostring(proxy))
  else
    local required = {"sha256", "encrypt", "decrypt", "random"}
    line("Required Tier 2+ methods:")
    for _, name in ipairs(required) do
      local available = type(proxy[name]) == "function"
      line("  " .. name .. ": " .. (available and "AVAILABLE" or "MISSING"))
    end

    local tier3 = {"generateKeyPair", "deserializeKey", "ecdh", "ecdsa"}
    line("Tier 3 asymmetric methods:")
    for _, name in ipairs(tier3) do
      local available = type(proxy[name]) == "function"
      line("  " .. name .. ": " .. (available and "AVAILABLE" or "MISSING"))
    end

    if type(proxy.sha256) == "function" then
      local ok, digest = pcall(proxy.sha256, "abc")
      line("SHA-256 test: " .. (ok and ("PASS (" .. hexLength(digest) .. ")") or ("FAIL: " .. tostring(digest))))
    end

    if type(proxy.random) == "function" then
      local ok, bytes = pcall(proxy.random, 16)
      line("Random test: " .. (ok and type(bytes) == "string" and #bytes == 16
        and "PASS (16 bytes returned)" or ("FAIL: " .. tostring(bytes))))
    end

    if type(proxy.encrypt) == "function" and type(proxy.decrypt) == "function" then
      local plain = "GALACTIC-STATION-DATA-CARD-TEST"
      local testKey = "GS-TEST-KEY-1234"
      local testIV = "GS-TEST-IV--1234"
      local encOK, cipher = pcall(proxy.encrypt, plain, testKey, testIV)
      if encOK and type(cipher) == "string" then
        local decOK, decoded = pcall(proxy.decrypt, cipher, testKey, testIV)
        line("AES round-trip: " .. (decOK and decoded == plain and "PASS" or ("FAIL: " .. tostring(decoded))))
      else
        line("AES round-trip: FAIL: " .. tostring(cipher))
      end
    end
  end
end

if count == 0 then
  line("")
  line("No component of type 'data' is attached to this computer.")
else
  line("")
  line("Detected data component count: " .. tostring(count))
  line("A working Tier 3 Data Card should expose Tier 2 crypto methods")
  line("(sha256, encrypt, decrypt, random) as well as Tier 3 EC methods.")
end

line("============================================================")
