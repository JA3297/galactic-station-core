-- Copy to /etc/station/acl.lua on BOTH security-pair computers.
-- This is an application-level allow-list, NOT cryptographic authentication.
-- Keep the station's modem network physically/logically trusted.
return {
  ["station_commander"] = {
    read = true,
    command = true,
    emergency = true,
    maintenance = true
  },
  ["engineering_officer"] = {
    read = true,
    command = true,
    maintenance = true
  },
  ["guest"] = {
    read = true
  }
}
